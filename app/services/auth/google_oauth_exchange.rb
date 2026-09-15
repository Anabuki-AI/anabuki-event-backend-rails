require "net/http"
require "uri"

# Shared Google OAuth helpers: authorization URL construction, server-side
# state persistence, code exchange, and ID token verification.
#
# Including classes must expose @config responding to #oauth_redirect_uri and
# the shared Auth::Config attributes, plus #state_model and #auth_error.
module Auth
  module GoogleOauthExchange
    GOOGLE_AUTHORIZATION_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
    GOOGLE_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"

    def google_authorization_url(state)
      query = URI.encode_www_form(
        client_id: @config.google_client_id,
        redirect_uri: @config.oauth_redirect_uri,
        response_type: "code",
        scope: "openid email",
        state:,
        nonce: state,
        prompt: "select_account"
      )
      "#{GOOGLE_AUTHORIZATION_ENDPOINT}?#{query}"
    end

    def create_oauth_state!(ttl)
      state = token
      state_model.create!(state_hash: digest(state), expires_at: ttl.from_now)
      state
    end

    def consume_oauth_state!(state)
      state_model.where(state_hash: digest(state)).where("expires_at > ?", Time.current).delete_all == 1
    end

    def exchange_and_verify!(code, state)
      response = Net::HTTP.post_form(URI(GOOGLE_TOKEN_ENDPOINT), code:, client_id: @config.google_client_id, client_secret: @config.google_client_secret, redirect_uri: @config.oauth_redirect_uri, grant_type: "authorization_code")
      raise auth_error.new("Google authentication failed", :bad_gateway) unless response.is_a?(Net::HTTPSuccess)

      id_token = JSON.parse(response.body).fetch("id_token")
      claims = Google::Auth::IDTokens.verify_oidc(id_token, aud: @config.google_client_id)
      valid = claims["email_verified"] == true || claims["email_verified"] == "true"
      valid &&= claims["nonce"] == state && claims["email"].present? && claims["sub"].present?
      raise auth_error.new("Google authentication failed", :bad_gateway) unless valid

      claims
    rescue JSON::ParserError, KeyError, Google::Auth::IDTokens::VerificationError, SocketError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout
      raise auth_error.new("Google authentication failed", :bad_gateway)
    end
  end
end
