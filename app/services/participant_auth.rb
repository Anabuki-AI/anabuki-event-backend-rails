# Cookie session authority for event participants. This is deliberately
# independent from AdminAuth: a participant has no Google identity or admin
# permissions, only an opaque browser session linked to a UUID participant.
class ParticipantAuth
  include Auth::CookieSession
  include Auth::TokenCrypto

  SESSION_COOKIE = "participant_session"
  SESSION_TTL = 30.days

  def initialize(cookies:, config: ParticipantAuthConfig.new)
    @cookies = cookies
    @config = config
  end

  def create_session!(participant)
    raw_token = token
    session = ParticipantSession.create!(
      participant:,
      token_hash: digest(raw_token),
      expires_at: SESSION_TTL.from_now
    )
    [ raw_token, session ]
  end

  def write_session_cookie!(raw_token)
    write_cookie(SESSION_COOKIE, raw_token, SESSION_TTL)
  end

  def current_session
    raw_token = @cookies[SESSION_COOKIE]
    return unless valid_token?(raw_token)

    session = ParticipantSession.includes(:participant).find_by(token_hash: digest(raw_token), revoked_at: nil)
    return unless session&.expires_at&.future?

    session
  end

  def current_session!
    current_session || raise(ParticipantAuthError.new("Participant session is required", :unauthorized))
  end

  def logout!
    raw_token = @cookies[SESSION_COOKIE]
    if valid_token?(raw_token)
      ParticipantSession.where(token_hash: digest(raw_token), revoked_at: nil).update_all(revoked_at: Time.current, updated_at: Time.current)
    end

    @cookies.delete(SESSION_COOKIE, cookie_options)
  end
end
