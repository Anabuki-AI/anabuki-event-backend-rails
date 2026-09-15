require "uri"

class OperatorAuthConfig
  include Auth::Config

  def operator_frontend_url = ENV.fetch("OPERATOR_FRONTEND_URL", "#{public_base_url}/operator")

  # The operator callback has a sane default derived from the public base URL,
  # but the Google OAuth client must have it registered as a redirect URI.
  def operator_google_oauth_callback_url = ENV.fetch("OPERATOR_GOOGLE_OAUTH_CALLBACK_URL", "#{public_base_url}/api/auth/operator/google/callback")

  def oauth_redirect_uri = operator_google_oauth_callback_url

  def oauth_configured?
    oauth_configured_for?(operator_frontend_url) && http_url?(operator_google_oauth_callback_url)
  end

  def allowed_origin?(origin)
    allow_origin?(origin, [ public_base_url, operator_frontend_url ])
  end

  def operator_email_allowlist = allowlisted_emails("OPERATOR_EMAIL_ALLOWLIST")
end
