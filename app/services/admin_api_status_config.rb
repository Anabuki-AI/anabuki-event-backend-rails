require "uri"

# Reads the external-monitoring configuration without ever returning credentials
# to a controller response. Each query is intentionally environment-configured:
# monitored services and metric names vary per deployment.
class AdminApiStatusConfig
  DEFAULT_STATUSPAGE_API_BASE_URL = "https://api.statuspage.io/v1"
  DEFAULT_DATADOG_SITE = "datadoghq.com"
  DEFAULT_CACHE_TTL_SECONDS = 60
  DEFAULT_METRICS_WINDOW_SECONDS = 300

  def statuspage_public_summary_url = optional_https_url("STATUSPAGE_PUBLIC_SUMMARY_URL")
  def statuspage_page_id = ENV.fetch("STATUSPAGE_PAGE_ID", "").strip
  def statuspage_api_key = ENV.fetch("STATUSPAGE_API_KEY", "")
  def statuspage_api_base_url = https_url_from("STATUSPAGE_API_BASE_URL", DEFAULT_STATUSPAGE_API_BASE_URL)

  def datadog_api_key = ENV.fetch("DATADOG_API_KEY", "")
  def datadog_app_key = ENV.fetch("DATADOG_APP_KEY", "")
  def datadog_site = ENV.fetch("DATADOG_SITE", DEFAULT_DATADOG_SITE).strip
  def datadog_api_base_url
    configured = ENV.fetch("DATADOG_API_BASE_URL", "").strip
    return https_url(configured) if configured.present?

    https_url("https://api.#{datadog_site}")
  end

  def datadog_error_rate_query = ENV.fetch("DATADOG_ERROR_RATE_QUERY", "").strip
  def datadog_response_time_query = ENV.fetch("DATADOG_RESPONSE_TIME_QUERY", "").strip
  def cache_ttl_seconds = bounded_integer("API_STATUS_CACHE_TTL_SECONDS", DEFAULT_CACHE_TTL_SECONDS, 0..300)
  def metrics_window_seconds = bounded_integer("DATADOG_METRICS_WINDOW_SECONDS", DEFAULT_METRICS_WINDOW_SECONDS, 60..3600)

  def statuspage_public_configured?
    statuspage_public_summary_url.present?
  end

  def statuspage_authenticated_configured?
    statuspage_page_id.present? && statuspage_api_key.present? && statuspage_api_base_url.present?
  end

  def datadog_credentials_configured?
    datadog_api_key.present? && datadog_app_key.present? && datadog_api_base_url.present?
  end

  def cache_fingerprint
    [
      statuspage_public_summary_url,
      statuspage_page_id,
      statuspage_api_base_url,
      datadog_api_base_url,
      datadog_error_rate_query,
      datadog_response_time_query,
      metrics_window_seconds
    ].join("\u0000")
  end

  private

  def optional_https_url(name)
    value = ENV.fetch(name, "").strip
    return if value.blank?

    https_url(value)
  end

  def https_url_from(name, default)
    https_url(ENV.fetch(name, default).strip)
  end

  def https_url(value)
    uri = URI.parse(value)
    return unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?

    uri.to_s.chomp("/")
  rescue URI::InvalidURIError
    nil
  end

  def bounded_integer(name, default, range)
    value = Integer(ENV.fetch(name, default.to_s), exception: false)
    value && range.cover?(value) ? value : default
  end
end
