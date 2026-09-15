require "digest"
require "securerandom"

# Participant sessions are deliberately independent of the Google-backed
# administration sessions. Cookies contain random secrets; PostgreSQL stores
# only their SHA-256 hashes.
class ParticipantAuth
  class SessionCreationError < StandardError; end

  DEVICE_COOKIE = "participant_device_id"
  SESSION_COOKIE = "participant_session"
  SESSION_TTL = 3.hours
  DEVICE_TTL = 365.days

  def initialize(cookies:, config: AdminAuthConfig.new)
    @cookies = cookies
    @config = config
  end

  def current_identity
    device = @cookies[DEVICE_COOKIE]
    key = @cookies[SESSION_COOKIE]
    return unless valid_token?(device) && valid_token?(key)

    session = ParticipantDeviceSession.includes(:participant_identity).find_by(
      device_id_hash: digest(device),
      session_key_hash: digest(key),
      revoked_at: nil
    )
    return unless session&.expires_at&.>(Time.current)

    session.update_columns(last_seen_at: Time.current, updated_at: Time.current)
    session.participant_identity
  end

  def establish_session!(identity)
    device = ensure_device_cookie!
    session_key = token
    now = Time.current

    ParticipantIdentity.transaction do
      identity.lock!
      ParticipantDeviceSession.where(participant_identity: identity, revoked_at: nil).update_all(revoked_at: now, updated_at: now)
      ParticipantDeviceSession.where(device_id_hash: digest(device), revoked_at: nil).update_all(revoked_at: now, updated_at: now)
      ParticipantDeviceSession.create!(
        participant_identity: identity,
        device_id_hash: digest(device),
        session_key_hash: digest(session_key),
        expires_at: SESSION_TTL.from_now,
        last_seen_at: now
      )
    end

    write_cookie(SESSION_COOKIE, session_key, SESSION_TTL)
  rescue ActiveRecord::RecordNotUnique
    raise SessionCreationError, "Participant session could not be created"
  end

  private

  def ensure_device_cookie!
    device = @cookies[DEVICE_COOKIE]
    return device if valid_token?(device)

    device = token
    write_cookie(DEVICE_COOKIE, device, DEVICE_TTL)
    device
  end

  def write_cookie(name, value, ttl)
    @cookies[name] = cookie_options.merge(value: value, expires: ttl.from_now)
  end

  def cookie_options
    { httponly: true, same_site: :lax, secure: @config.secure_cookies?, path: "/" }
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
end
