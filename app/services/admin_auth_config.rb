class AdminAuthConfig
  def public_base_url = ENV.fetch("PUBLIC_BASE_URL", "http://localhost:3000")
  def admin_frontend_url = ENV.fetch("ADMIN_FRONTEND_URL", "#{public_base_url}/admin")
  def google_oauth_callback_url = ENV.fetch("GOOGLE_OAUTH_CALLBACK_URL", "")
  def google_client_id = ENV.fetch("GOOGLE_CLIENT_ID", "")
  def google_client_secret = ENV.fetch("GOOGLE_CLIENT_SECRET", "")

  def oauth_configured?
    [ google_oauth_callback_url, google_client_id, google_client_secret, admin_frontend_url ].all?(&:present?) &&
      [ google_oauth_callback_url, admin_frontend_url ].all? { |value| http_url?(value) }
  end

  def secure_cookies?
    URI.parse(public_base_url).scheme == "https"
  rescue URI::InvalidURIError
    false
  end

  def allowed_origin?(origin)
    [ public_base_url, admin_frontend_url ].any? { |value| same_origin?(origin, value) }
  end

  def environment_access_emails
    ENV.fetch("ADMIN_EMAIL_ALLOWLIST", "").split(",").filter_map do |email|
      normalized = email.strip.downcase
      normalized if normalized.match?(URI::MailTo::EMAIL_REGEXP) && !normalized.match?(/[\s,]/)
    end.to_set
  end

  private

  def http_url?(value)
    uri = URI.parse(value)
    uri.host.present? && %w[http https].include?(uri.scheme)
  rescue URI::InvalidURIError
    false
  end

  def same_origin?(left, right)
    a = URI.parse(left)
    b = URI.parse(right)
    a.scheme&.casecmp?(b.scheme) && a.host&.casecmp?(b.host) && port(a) == port(b)
  rescue URI::InvalidURIError
    false
  end

  def port(uri)
    uri.port || (uri.scheme == "https" ? 443 : 80)
  end
end
