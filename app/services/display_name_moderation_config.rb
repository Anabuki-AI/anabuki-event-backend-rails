require "uri"

# OpenRouter Decisions API (TypeSafe Jev) settings for participant
# display-name moderation. The API key is read from the environment only;
# it is never copied into responses, logs, or the request body.
class DisplayNameModerationConfig
  DEFAULT_API_URL = "https://openrouter.ai/api/alpha/decisions"
  DEFAULT_MODEL = "~typesafe/jev-latest"
  DEFAULT_THRESHOLD = 0.7

  def api_key = ENV.fetch("OPENROUTER_API_KEY", "")
  def model = ENV.fetch("OPENROUTER_MODEL", "").strip.presence || DEFAULT_MODEL
  def api_url = https_url_from("OPENROUTER_API_URL", DEFAULT_API_URL)
  def threshold = bounded_float("DISPLAY_NAME_MODERATION_THRESHOLD", DEFAULT_THRESHOLD, 0.0..1.0)
  def fail_closed? = ENV.fetch("DISPLAY_NAME_MODERATION_FAIL_CLOSED", "").strip == "true"

  def enabled?
    api_key.present? && api_url.present?
  end

  private

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

  def bounded_float(name, default, range)
    value = Float(ENV.fetch(name, default.to_s), exception: false)
    value && range.cover?(value) ? value : default
  end
end
