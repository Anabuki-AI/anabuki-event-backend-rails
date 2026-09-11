require "base64"
require "digest"
require "net/http"
require "securerandom"
require "uri"

# Implements the device-bound admin approval flow without ever storing a raw
# cookie or exposing a device/session hash in an API response.
class AdminAuth
  DEVICE_COOKIE = "admin_device_id"
  SESSION_COOKIE = "admin_session"
  APPLICANT_SESSION_COOKIE = "admin_applicant_session"
  OAUTH_STATE_COOKIE = "admin_oauth_state"
  APPLICANT_TTL = 20.minutes
  MANAGEMENT_TTL = 8.hours
  DEVICE_TTL = 365.days
  STATE_TTL = 10.minutes

  Session = Data.define(:record, :identity, :source, :permissions) do
    def applicant? = source == "APPLICANT"
    def allowed?(permission) = permissions.include?(permission)
  end

  def initialize(cookies:, config: AdminAuthConfig.new)
    @cookies = cookies
    @config = config
  end

  def oauth_configured? = @config.oauth_configured?

  def begin_oauth!
    configured!
    ensure_device_cookie!
    state = token
    AdminOauthState.create!(state_hash: digest(state), expires_at: STATE_TTL.from_now)
    write_cookie(OAUTH_STATE_COOKIE, state, STATE_TTL)
    query = URI.encode_www_form(
      client_id: @config.google_client_id,
      redirect_uri: @config.google_oauth_callback_url,
      response_type: "code",
      scope: "openid email",
      state:,
      nonce: state,
      prompt: "select_account"
    )
    "https://accounts.google.com/o/oauth2/v2/auth?#{query}"
  end

  def complete_oauth!(code:, state:)
    configured!
    raise AdminAuthError.new("OAuth callback is missing code or state", :bad_request) if code.blank? || state.blank?

    cookie_state = @cookies[OAUTH_STATE_COOKIE]
    unless cookie_state.present? && secure_equal?(state, cookie_state) && consume_state!(state)
      raise AdminAuthError.new("OAuth state validation failed", :bad_request)
    end

    claims = exchange_and_verify!(code, state)
    identity = find_or_create_identity!(claims.fetch("email"), claims.fetch("sub"))
    source = environment_access?(identity.email) ? "ENVIRONMENT_ACCESS" : (identity.admin_enabled? ? "MANAGEMENT_ACCESS" : "APPLICANT")
    session_key = token
    upsert_device_session!(identity:, session_key:, source:)
    write_cookie(source == "APPLICANT" ? APPLICANT_SESSION_COOKIE : SESSION_COOKIE, session_key, source == "APPLICANT" ? APPLICANT_TTL : MANAGEMENT_TTL)
    @cookies.delete(OAUTH_STATE_COOKIE, cookie_options)
    @config.admin_frontend_url
  end

  def any_session!
    read_session(SESSION_COOKIE) || read_session(APPLICANT_SESSION_COOKIE) || unauthorized!
  end

  def applicant_session!
    session = read_session(APPLICANT_SESSION_COOKIE) || unauthorized!
    raise AdminAuthError.new("Applicant access is required", :forbidden) unless session.applicant?

    session
  end

  def management_session!(permission = nil)
    session = any_session!
    raise AdminAuthError.new("Management page access is required", :forbidden) if session.applicant?
    raise AdminAuthError.new("Required permission is missing", :forbidden) if permission && !session.allowed?(permission)

    session
  end

  def logout!
    device = @cookies[DEVICE_COOKIE]
    [ SESSION_COOKIE, APPLICANT_SESSION_COOKIE ].each do |name|
      key = @cookies[name]
      revoke_session!(device, key, "APPLICANT_LOGGED_OUT") if device.present? && key.present?
      @cookies.delete(name, cookie_options)
    end
  end

  def own_access_request!
    device, key = applicant_cookie_pair!
    cancel_invalid_pending_requests!
    request = AdminAccessRequest.where(applicant_device_id_hash: digest(device), applicant_session_key_hash: digest(key)).order(id: :desc).first
    return request if request

    applicant_session!
    nil
  end

  def create_access_request!
    session = applicant_session!
    device, key = applicant_cookie_pair!
    now = Time.current
    AdminAccessRequest.transaction do
      cancel_invalid_pending_requests!(now)
      record = AdminDeviceSession.lock.find_by(id: session.record.id, device_id_hash: digest(device), session_key_hash: digest(key), access_source: "APPLICANT", revoked_at: nil)
      unauthorized! unless record&.expires_at&.>(now)
      AdminAccessRequest.pending.lock.where(applicant_session_id: record.id).first || AdminAccessRequest.create!(
        email: session.identity.email,
        google_sub: session.identity.google_sub,
        status: "PENDING",
        expires_at: record.expires_at,
        applicant_session: record,
        applicant_device_id_hash: digest(device),
        applicant_session_key_hash: digest(key)
      )
    end
  end

  def pending_access_requests!
    management_session!("ACCESS_REQUEST_APPROVE")
    cancel_invalid_pending_requests!
    AdminAccessRequest.pending.where("expires_at > ?", Time.current).order(:created_at).to_a
  end

  def decide_access_request!(id:, approved:)
    actor = management_session!("ACCESS_REQUEST_APPROVE")
    AdminAccessRequest.transaction do
      cancel_invalid_pending_requests!
      request = AdminAccessRequest.lock.find(id)
      raise AdminAuthError.new("The access request is no longer pending", :conflict) unless request.pending?

      session = AdminDeviceSession.lock.find_by(id: request.applicant_session_id)
      unless valid_binding?(request, session)
        cancel_request!(request, session&.expires_at && session.expires_at <= Time.current ? "APPLICANT_SESSION_EXPIRED" : "APPLICANT_SESSION_REVOKED")
        raise AdminAuthError.new("The access request is no longer pending", :conflict)
      end

      if approved
        identity = AdminIdentity.lock.find_by(google_sub: request.google_sub)
        raise AdminAuthError.new("The applicant Google identity could not be verified", :conflict) unless identity&.email == request.email

        identity.update!(admin_enabled: true, granted_by: actor.identity.id, granted_at: Time.current, revoked_at: nil)
        request.update!(status: "APPROVED", approved_by_email: actor.identity.email, approved_by_google_sub: actor.identity.google_sub, approved_by_identity_id: actor.identity.id, approved_at: Time.current)
      else
        request.update!(status: "REJECTED", rejected_by_email: actor.identity.email, rejected_by_google_sub: actor.identity.google_sub, rejected_by_identity_id: actor.identity.id, rejected_at: Time.current)
      end
      request
    end
  end

  def exchange_applicant_session!
    session = applicant_session!
    device, old_key = applicant_cookie_pair!
    next_key = token
    AdminDeviceSession.transaction do
      record = AdminDeviceSession.lock.find_by(id: session.record.id, device_id_hash: digest(device), session_key_hash: digest(old_key), access_source: "APPLICANT", revoked_at: nil)
      approved = record && AdminAccessRequest.approved.where(applicant_session_id: record.id, applicant_device_id_hash: digest(device), applicant_session_key_hash: digest(old_key), google_sub: session.identity.google_sub).exists?
      unless record&.expires_at&.>(Time.current) && approved && session.identity.admin_enabled?
        raise AdminAuthError.new("The approved applicant session cannot be exchanged", :forbidden)
      end

      record.update!(session_key_hash: digest(next_key), access_source: "MANAGEMENT_ACCESS", expires_at: MANAGEMENT_TTL.from_now, last_seen_at: Time.current)
    end
    write_cookie(SESSION_COOKIE, next_key, MANAGEMENT_TTL)
    @cookies.delete(APPLICANT_SESSION_COOKIE, cookie_options)
  end

  def management_accesses!
    management_session!("MANAGEMENT_PAGE_VIEW")
    environment = @config.environment_access_emails
    entries = environment.map { |email| { id: nil, email:, source: "ENVIRONMENT_ACCESS", active: true } }
    entries.concat(AdminIdentity.where("admin_enabled = true OR revoked_at IS NOT NULL").where.not(email: environment).order(:email).map do |identity|
      { id: identity.id, email: identity.email, source: "MANAGEMENT_ACCESS", active: identity.admin_enabled? }
    end)
    entries.sort_by { |entry| entry[:email] }
  end

  def deactivate_management_access!(id)
    management_session!("MANAGEMENT_ACCESS_REVOKE")
    identity = AdminIdentity.find(id)
    raise AdminAuthError.new("Environment management access cannot be deactivated", :forbidden) if environment_access?(identity.email)
    raise AdminAuthError.new("Management access is already inactive or cannot be deactivated", :bad_request) unless identity.admin_enabled?

    AdminIdentity.transaction do
      identity.lock!
      raise AdminAuthError.new("Management access is already inactive or cannot be deactivated", :bad_request) unless identity.admin_enabled?

      now = Time.current
      identity.update!(admin_enabled: false, revoked_at: now)
      sessions = identity.admin_device_sessions.lock.where(revoked_at: nil)
      cancel_requests_for_sessions!(sessions, "APPLICANT_SESSION_REVOKED", now)
      sessions.update_all(revoked_at: now, updated_at: now)
    end
  end

  private

  def read_session(cookie_name)
    device = @cookies[DEVICE_COOKIE]
    key = @cookies[cookie_name]
    return if device.blank? || key.blank?

    now = Time.current
    record = AdminDeviceSession.includes(:admin_identity).find_by(device_id_hash: digest(device), session_key_hash: digest(key), revoked_at: nil)
    return unless record&.expires_at&.>(now)

    record.update_columns(last_seen_at: now, updated_at: now)
    identity = record.admin_identity
    return unless identity && identity.email == record.email && identity.google_sub == record.google_sub

    if environment_access?(identity.email)
      Session.new(record, identity, "ENVIRONMENT_ACCESS", %w[MANAGEMENT_PAGE_VIEW ACCESS_REQUEST_APPROVE MANAGEMENT_ACCESS_REVOKE])
    elsif identity.admin_enabled? && (record.management_access? || record.environment_access?)
      Session.new(record, identity, "MANAGEMENT_ACCESS", %w[MANAGEMENT_PAGE_VIEW ACCESS_REQUEST_APPROVE])
    else
      Session.new(record, identity, "APPLICANT", [])
    end
  end

  def upsert_device_session!(identity:, session_key:, source:)
    device = ensure_device_cookie!
    now = Time.current
    AdminDeviceSession.transaction do
      current = AdminDeviceSession.lock.find_by(device_id_hash: digest(device))
      if current&.applicant? && (current.session_key_hash != digest(session_key) || source != "APPLICANT")
        cancel_requests_for_sessions!(AdminDeviceSession.where(id: current.id), "APPLICANT_SESSION_REVOKED", now)
      end
      current ||= AdminDeviceSession.new(device_id_hash: digest(device))
      current.update!(admin_identity: identity, session_key_hash: digest(session_key), email: identity.email, google_sub: identity.google_sub, access_source: source, expires_at: (source == "APPLICANT" ? APPLICANT_TTL : MANAGEMENT_TTL).from_now, last_seen_at: now, revoked_at: nil)
      current
    end
  end

  def find_or_create_identity!(email, google_sub)
    normalized_email = email.to_s.strip.downcase
    raise AdminAuthError.new("Google authentication failed", :bad_gateway) unless normalized_email.match?(URI::MailTo::EMAIL_REGEXP) && google_sub.present?

    AdminIdentity.transaction do
      by_sub = AdminIdentity.lock.find_by(google_sub:)
      if by_sub
        raise AdminAuthError.new("This Google account is linked to another email", :conflict) unless by_sub.email == normalized_email
        return by_sub
      end
      by_email = AdminIdentity.lock.find_by(email: normalized_email)
      raise AdminAuthError.new("This email is linked to another Google account", :conflict) if by_email

      AdminIdentity.create!(email: normalized_email, google_sub:)
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def exchange_and_verify!(code, state)
    response = Net::HTTP.post_form(URI("https://oauth2.googleapis.com/token"), code:, client_id: @config.google_client_id, client_secret: @config.google_client_secret, redirect_uri: @config.google_oauth_callback_url, grant_type: "authorization_code")
    raise AdminAuthError.new("Google authentication failed", :bad_gateway) unless response.is_a?(Net::HTTPSuccess)

    id_token = JSON.parse(response.body).fetch("id_token")
    claims = Google::Auth::IDTokens.verify_oidc(id_token, aud: @config.google_client_id)
    valid = claims["email_verified"] == true || claims["email_verified"] == "true"
    valid &&= claims["nonce"] == state && claims["email"].present? && claims["sub"].present?
    raise AdminAuthError.new("Google authentication failed", :bad_gateway) unless valid

    claims
  rescue JSON::ParserError, KeyError, Google::Auth::IDTokens::VerificationError, SocketError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout
    raise AdminAuthError.new("Google authentication failed", :bad_gateway)
  end

  def consume_state!(state)
    AdminOauthState.where(state_hash: digest(state)).where("expires_at > ?", Time.current).delete_all == 1
  end

  def cancel_invalid_pending_requests!(now = Time.current)
    AdminAccessRequest.pending.includes(:applicant_session).find_each do |request|
      session = request.applicant_session
      next if valid_binding?(request, session, now)

      cancel_request!(request, session&.expires_at && session.expires_at <= now ? "APPLICANT_SESSION_EXPIRED" : "APPLICANT_SESSION_REVOKED", now)
    end
  end

  def cancel_requests_for_sessions!(sessions, reason, now)
    AdminAccessRequest.pending.where(applicant_session_id: sessions.select(:id)).update_all(status: "CANCELLED", cancelled_at: now, cancellation_reason: reason, updated_at: now)
  end

  def cancel_request!(request, reason, now = Time.current)
    request.update!(status: "CANCELLED", cancelled_at: now, cancellation_reason: reason)
  end

  def valid_binding?(request, session, now = Time.current)
    session && session.applicant? && session.revoked_at.nil? && request.expires_at > now && session.expires_at > now &&
      secure_equal?(request.applicant_device_id_hash, session.device_id_hash) && secure_equal?(request.applicant_session_key_hash, session.session_key_hash) &&
      request.email == session.email && request.google_sub == session.google_sub
  end

  def applicant_cookie_pair!
    device = @cookies[DEVICE_COOKIE]
    key = @cookies[APPLICANT_SESSION_COOKIE]
    unauthorized! if device.blank? || key.blank?
    [ device, key ]
  end

  def revoke_session!(device, key, reason)
    record = AdminDeviceSession.lock.find_by(device_id_hash: digest(device), session_key_hash: digest(key))
    return unless record

    AdminDeviceSession.transaction do
      cancel_requests_for_sessions!(AdminDeviceSession.where(id: record.id), reason, Time.current) if record.applicant?
      record.update!(revoked_at: Time.current)
    end
  end

  def ensure_device_cookie!
    device = @cookies[DEVICE_COOKIE]
    return device if valid_token?(device)

    device = token
    write_cookie(DEVICE_COOKIE, device, DEVICE_TTL)
    device
  end

  def write_cookie(name, value, ttl)
    @cookies[name] = cookie_options.merge(value:, expires: ttl.from_now)
  end

  def cookie_options
    { httponly: true, same_site: :lax, secure: @config.secure_cookies?, path: "/" }
  end

  def environment_access?(email)
    @config.environment_access_emails.include?(email)
  end

  def configured!
    raise AdminAuthError.new("Google OAuth is not configured", :service_unavailable) unless oauth_configured?
  end

  def unauthorized!
    raise AdminAuthError.new("Authentication is required", :unauthorized)
  end

  def token
    SecureRandom.urlsafe_base64(32, false)
  end

  def digest(value)
    Digest::SHA256.digest(value)
  end

  def valid_token?(value)
    value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]{40,64}\z/)
  end

  def secure_equal?(left, right)
    left.is_a?(String) && right.is_a?(String) && left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
  end
end
