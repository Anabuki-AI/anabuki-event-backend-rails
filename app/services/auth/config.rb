require "uri"

# Shared configuration surface for AdminAuthConfig and OperatorAuthConfig:
# public base URL, Google OAuth credentials, cookie security, and origin
# validation.
module Auth
  module Config
    def public_base_url = ENV.fetch("PUBLIC_BASE_URL", "http://localhost:3000")

    # Extra origins allowed alongside PUBLIC_BASE_URL / ADMIN_FRONTEND_URL /
    # OPERATOR_FRONTEND_URL, comma-separated (same convention as the email
    # allowlists below). Event-day dev servers are reached from several
    # participant phones over LAN Wi-Fi at once, so a single PUBLIC_BASE_URL
    # is not enough; this lets ops add those origins without widening the
    # check to a wildcard.
    def additional_allowed_origins
      ENV.fetch("ADDITIONAL_ALLOWED_ORIGINS", "").split(",").filter_map { |value| value.strip.presence }
    end

    def google_client_id = ENV.fetch("GOOGLE_CLIENT_ID", "")

    def google_client_secret = ENV.fetch("GOOGLE_CLIENT_SECRET", "")

    # Each concrete config defines its own Google OAuth redirect URI.
    # (abstract)

    def oauth_configured_for?(frontend_url)
      [ oauth_redirect_uri, google_client_id, google_client_secret, frontend_url ].all?(&:present?) &&
        [ oauth_redirect_uri, frontend_url ].all? { |value| http_url?(value) }
    end

    def secure_cookies?
      URI.parse(public_base_url).scheme == "https"
    rescue URI::InvalidURIError
      false
    end

    def allow_origin?(origin, allowed_urls)
      source = URI.parse(origin)
      return false unless source.is_a?(URI::HTTP) && source.host.present? && source.userinfo.nil? &&
        source.path.empty? && source.query.nil? && source.fragment.nil?

      (allowed_urls + additional_allowed_origins).any? { |value| same_origin?(source, value) }
    rescue URI::InvalidURIError
      false
    end

    def allowlisted_emails(env_key)
      ENV.fetch(env_key, "").split(",").filter_map do |email|
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

    def same_origin?(source, url)
      target = URI.parse(url)
      source.scheme.casecmp?(target.scheme) && source.host.casecmp?(target.host) && source.port == target.port
    rescue URI::InvalidURIError
      false
    end
  end
end
