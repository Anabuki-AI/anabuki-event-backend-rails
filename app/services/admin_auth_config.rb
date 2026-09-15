class AdminAuthConfig
  include Auth::Config

  def admin_frontend_url = ENV.fetch("ADMIN_FRONTEND_URL", "#{public_base_url}/admin")

  def google_oauth_callback_url = ENV.fetch("GOOGLE_OAUTH_CALLBACK_URL", "")

  def oauth_redirect_uri = google_oauth_callback_url

  def oauth_configured? = oauth_configured_for?(admin_frontend_url)

  def allowed_origin?(origin)
    allow_origin?(origin, [ public_base_url, admin_frontend_url ])
  end

  def environment_access_emails = allowlisted_emails("ADMIN_EMAIL_ALLOWLIST")
end
