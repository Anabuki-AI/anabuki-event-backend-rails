require "uri"

# Device-bound session flow for event operators. Identity and session data
# live in the dedicated operator database, and only allowlisted emails may
# sign in. There is no access-request governance here; that remains an
# admin-only capability.
class OperatorAuth
  include Auth::TokenCrypto
  include Auth::CookieSession
  include Auth::GoogleOauthExchange

  DEVICE_COOKIE = "operator_device_id"
  SESSION_COOKIE = "operator_session"
  OAUTH_STATE_COOKIE = "operator_oauth_state"
  SESSION_TTL = 8.hours
  DEVICE_TTL = 365.days
  STATE_TTL = 10.minutes

  Session = Data.define(:record, :identity)

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
    email = claims.fetch("email").to_s.strip.downcase
    unless email.match?(URI::MailTo::EMAIL_REGEXP) && @config.operator_email_allowlist.include?(email)
      raise auth_error.new("Operator access is not allowed for this account", :forbidden)
    end

    identity = find_or_create_identity!(email, claims.fetch("sub"))
    session_key = token
    upsert_device_session!(identity:, session_key:)
    write_cookie(SESSION_COOKIE, session_key, SESSION_TTL)
    @cookies.delete(OAUTH_STATE_COOKIE, cookie_options)
    @config.operator_frontend_url
  end

  def session!
    device = @cookies[DEVICE_COOKIE]
    key = @cookies[SESSION_COOKIE]
    return unauthorized! if device.blank? || key.blank?

    now = Time.current
    record = Operator::DeviceSession.includes(:operator_identity).find_by(device_id_hash: digest(device), session_key_hash: digest(key), revoked_at: nil)
    return unauthorized! unless record&.expires_at&.>(now) && record.manager?

    record.update_columns(last_seen_at: now, updated_at: now)
    identity = record.operator_identity
    return unauthorized! unless identity && identity.email == record.email && identity.google_sub == record.google_sub

    Session.new(record, identity)
  end

  def logout!
    device = @cookies[DEVICE_COOKIE]
    key = @cookies[SESSION_COOKIE]
    if device.present? && key.present?
      record = Operator::DeviceSession.find_by(device_id_hash: digest(device), session_key_hash: digest(key))
      record&.update!(revoked_at: Time.current)
    end
    @cookies.delete(SESSION_COOKIE, cookie_options)
  end

  private

  def auth_error = OperatorAuthError

  def state_model = Operator::OauthState

  def find_or_create_identity!(email, google_sub)
    Operator::Identity.transaction do
      by_sub = Operator::Identity.lock.find_by(google_sub:)
      if by_sub
        raise auth_error.new("This Google account is linked to another email", :conflict) unless by_sub.email == email
        return by_sub
      end
      by_email = Operator::Identity.lock.find_by(email: email)
      raise auth_error.new("This email is linked to another Google account", :conflict) if by_email

      Operator::Identity.create!(email:, google_sub:)
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def upsert_device_session!(identity:, session_key:)
    device = ensure_device_cookie!(DEVICE_COOKIE, DEVICE_TTL)
    now = Time.current
    Operator::DeviceSession.transaction do
      record = Operator::DeviceSession.lock.find_by(device_id_hash: digest(device))
      if record
        record.update!(operator_identity: identity, session_key_hash: digest(session_key), email: identity.email, google_sub: identity.google_sub, access_source: "MANAGER", expires_at: SESSION_TTL.from_now, last_seen_at: now, revoked_at: nil)
      else
        Operator::DeviceSession.create!(operator_identity: identity, device_id_hash: digest(device), session_key_hash: digest(session_key), email: identity.email, google_sub: identity.google_sub, access_source: "MANAGER", expires_at: SESSION_TTL.from_now, last_seen_at: now)
      end
    end
  end

  def configured!
    raise auth_error.new("Google OAuth is not configured", :service_unavailable) unless oauth_configured?
  end

  def unauthorized!
    raise auth_error.new("Authentication is required", :unauthorized)
  end
end
