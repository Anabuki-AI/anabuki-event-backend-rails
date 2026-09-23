require "uri"

# Device-bound session flow for event operators. Identity and session data
# live in the primary database. Operator access is granted directly
# by an administrator to a Google-authenticated identity; allowlisted emails
# remain an optional environment-level source of access.
class OperatorAuth
  include Auth::TokenCrypto
  include Auth::CookieSession
  include Auth::GoogleOauthExchange

  DEVICE_COOKIE = "operator_device_id"
  SESSION_COOKIE = "operator_session"
  APPLICANT_SESSION_COOKIE = "operator_applicant_session"
  OAUTH_STATE_COOKIE = "operator_oauth_state"
  APPLICANT_TTL = 20.minutes
  SESSION_TTL = 3.weeks
  DEVICE_TTL = 365.days
  STATE_TTL = 10.minutes

  Session = Data.define(:record, :identity, :source) do
    def applicant? = source == "APPLICANT"
    def manager? = source == "MANAGER"
  end

  def initialize(cookies:, config: OperatorAuthConfig.new)
    @cookies = cookies
    @config = config
  end

  def oauth_configured? = @config.oauth_configured?

  def begin_oauth!
    configured!
    ensure_device_cookie!(DEVICE_COOKIE, DEVICE_TTL)
    state = create_oauth_state!(STATE_TTL)
    write_cookie(OAUTH_STATE_COOKIE, state, STATE_TTL)
    google_authorization_url(state)
  end

  def complete_oauth!(code:, state:)
    configured!
    raise auth_error.new("OAuth callback is missing code or state", :bad_request) if code.blank? || state.blank?

    cookie_state = @cookies[OAUTH_STATE_COOKIE]
    unless cookie_state.present? && secure_equal?(state, cookie_state) && consume_oauth_state!(state)
      raise auth_error.new("OAuth state validation failed", :bad_request)
    end

    claims = exchange_and_verify!(code, state)
    identity = find_or_create_identity!(claims.fetch("email"), claims.fetch("sub"))
    source = manager_access?(identity) ? "MANAGER" : "APPLICANT"
    session_key = token
    upsert_device_session!(identity:, session_key:, source:)
    # Mirrors AdminAuth: only a real manager login is audit-worthy, matching
    # ADMIN_LOGIN_SUCCEEDED skipping plain applicant sign-ins.
    AuditLogRecorder.record(type: "OPERATOR_LOGIN_SUCCEEDED", identity:) if source == "MANAGER"
    write_cookie(source == "APPLICANT" ? APPLICANT_SESSION_COOKIE : SESSION_COOKIE, session_key, source == "APPLICANT" ? APPLICANT_TTL : SESSION_TTL)
    @cookies.delete(OAUTH_STATE_COOKIE, cookie_options)
    @config.operator_frontend_url
  end

  def any_session!
    read_session(SESSION_COOKIE) || read_session(APPLICANT_SESSION_COOKIE) || unauthorized!
  end

  def manager_session!
    session = any_session!
    raise auth_error.new("Operator management access is required", :forbidden) unless session.manager?

    session
  end

  def logout!
    device = @cookies[DEVICE_COOKIE]
    [ SESSION_COOKIE, APPLICANT_SESSION_COOKIE ].each do |name|
      key = @cookies[name]
      revoke_session!(device, key) if device.present? && key.present?
      @cookies.delete(name, cookie_options)
    end
  end

  # Only identities created by a completed operator Google login are listed.
  # No email-address entry point exists, preventing grants to unverified users.
  def management_identities!
    # Encrypted columns cannot be ordered by their decrypted value in SQL.
    Operator::Identity.all.sort_by(&:email).map { |identity| management_identity_json(identity) }
  end

  def management_identity_json(identity)
    {
      id: identity.id,
      email: identity.email,
      active: manager_access?(identity),
      managerEnabled: identity.manager_enabled?,
      source: @config.operator_email_allowlist.include?(identity.email) ? "ENVIRONMENT_ACCESS" : "MANAGEMENT_ACCESS"
    }
  end

  def set_management_access!(id:, manager_enabled:, actor:)
    Operator::Identity.transaction do
      identity = Operator::Identity.lock.find(id)
      raise auth_error.new("Operator access is controlled by the environment allowlist", :bad_request) if @config.operator_email_allowlist.include?(identity.email)

      now = Time.current
      attributes = { manager_enabled:, revoked_at: manager_enabled ? nil : now }
      # Keep the original granting actor and timestamp after revocation, matching
      # the administrator access audit trail. A new direct grant records its own
      # actor and timestamp.
      attributes.merge!(granted_by: actor.identity.id, granted_at: now) if manager_enabled
      identity.update!(attributes)
      identity.operator_device_sessions.where(revoked_at: nil).update_all(revoked_at: now, updated_at: now) unless manager_access?(identity)
      identity
    end
  end

  private

  def auth_error = OperatorAuthError

  def state_model = Operator::OauthState

  def read_session(cookie_name)
    device = @cookies[DEVICE_COOKIE]
    key = @cookies[cookie_name]
    return if device.blank? || key.blank?

    now = Time.current
    record = Operator::DeviceSession.includes(:operator_identity).find_by(device_id_hash: digest(device), session_key_hash: digest(key), revoked_at: nil)
    return unless record&.expires_at&.>(now)

    record.update_columns(last_seen_at: now, updated_at: now)
    identity = record.operator_identity
    return unless identity && identity.email == record.email && identity.google_sub == record.google_sub

    # A direct grant takes effect for a current applicant cookie as well. The
    # next Google login creates the normal three-week manager session; this
    # avoids making a newly granted operator sign in again before starting work.
    Session.new(record, identity, manager_access?(identity) ? "MANAGER" : "APPLICANT")
  end

  def manager_access?(identity)
    @config.operator_email_allowlist.include?(identity.email) || identity.manager_enabled?
  end

  def upsert_device_session!(identity:, session_key:, source:)
    device = ensure_device_cookie!(DEVICE_COOKIE, DEVICE_TTL)
    now = Time.current
    Operator::DeviceSession.transaction do
      current = Operator::DeviceSession.lock.find_by(device_id_hash: digest(device))
      current ||= Operator::DeviceSession.new(device_id_hash: digest(device))
      current.update!(operator_identity: identity, session_key_hash: digest(session_key), email: identity.email, google_sub: identity.google_sub, access_source: source, expires_at: (source == "APPLICANT" ? APPLICANT_TTL : SESSION_TTL).from_now, last_seen_at: now, revoked_at: nil)
      current
    end
  end

  def find_or_create_identity!(email, google_sub)
    normalized_email = email.to_s.strip.downcase
    raise auth_error.new("Google authentication failed", :bad_gateway) unless normalized_email.match?(URI::MailTo::EMAIL_REGEXP) && google_sub.present?

    Operator::Identity.transaction do
      by_sub = Operator::Identity.lock.find_by(google_sub:)
      if by_sub
        raise auth_error.new("This Google account is linked to another email", :conflict) unless by_sub.email == normalized_email
        return by_sub
      end
      by_email = Operator::Identity.lock.find_by(email: normalized_email)
      raise auth_error.new("This email is linked to another Google account", :conflict) if by_email

      Operator::Identity.create!(email: normalized_email, google_sub:)
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def revoke_session!(device, key)
    record = Operator::DeviceSession.lock.find_by(device_id_hash: digest(device), session_key_hash: digest(key))
    record&.update!(revoked_at: Time.current)
  end

  def configured!
    raise auth_error.new("Google OAuth is not configured", :service_unavailable) unless oauth_configured?
  end

  def unauthorized!
    raise auth_error.new("Authentication is required", :unauthorized)
  end
end
