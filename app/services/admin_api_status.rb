require "digest"
require "json"
require "uri"

# Produces a presentation-safe snapshot of external monitoring data. Provider
# credentials and configured metric queries remain server-side; callers only
# receive normalized values and deliberately generic failure information.
class AdminApiStatus
  STATUSPAGE_INDICATORS = {
    "none" => "operational",
    "minor" => "degraded",
    "major" => "partial_outage",
    "critical" => "major_outage"
  }.freeze

  def initialize(config: AdminApiStatusConfig.new, cache: Rails.cache, transport: AdminApiStatusTransport.new, clock: -> { Time.current })
    @config = config
    @cache = cache
    @transport = transport
    @clock = clock
  end

  def call
    cached = read_cache
    return cached.merge("cached" => true) if cached

    snapshot = {
      "generatedAt" => now_iso8601,
      "cached" => false,
      "providers" => [ statuspage_snapshot, datadog_snapshot ]
    }
    write_cache(snapshot)
    snapshot
  end

  private

  attr_reader :config, :cache, :transport, :clock

  def statuspage_snapshot
    if config.statuspage_public_configured?
      statuspage_summary_snapshot
    elsif config.statuspage_authenticated_configured?
      statuspage_authenticated_snapshot
    else
      unconfigured_provider("statuspage", "Statuspage", "Configure STATUSPAGE_PUBLIC_SUMMARY_URL, or STATUSPAGE_PAGE_ID and STATUSPAGE_API_KEY.")
    end
  rescue AdminApiStatusTransport::Error, JSON::ParserError
    failed_provider("statuspage", "Statuspage", "Statuspage data could not be retrieved.")
  end

  def statuspage_summary_snapshot
    response = transport.request(
      method: :get,
      url: config.statuspage_public_summary_url,
      headers: default_headers
    )
    raise AdminApiStatusTransport::Error unless success?(response)

    body = parse_json(response.body)
    status = body.fetch("status")
    statuspage_provider(status.fetch("indicator"), status["description"])
  rescue KeyError, TypeError, NoMethodError
    failed_provider("statuspage", "Statuspage", "Statuspage returned an unexpected response.")
  end

  def statuspage_authenticated_snapshot
    page_id = URI.encode_www_form_component(config.statuspage_page_id)
    response = transport.request(
      method: :get,
      url: "#{config.statuspage_api_base_url}/pages/#{page_id}",
      headers: default_headers.merge("Authorization" => "OAuth #{config.statuspage_api_key}")
    )
    raise AdminApiStatusTransport::Error unless success?(response)

    body = parse_json(response.body)
    statuspage_provider(body.fetch("status_indicator"), body["status_description"])
  rescue KeyError, TypeError, NoMethodError
    failed_provider("statuspage", "Statuspage", "Statuspage returned an unexpected response.")
  end

  def statuspage_provider(indicator, description)
    availability = STATUSPAGE_INDICATORS.fetch(indicator.to_s, "unknown")
    {
      "provider" => "statuspage",
      "source" => "Statuspage",
      "state" => "available",
      "fetchedAt" => now_iso8601,
      "availability" => {
        "state" => "available",
        "value" => availability,
        "externalStatus" => description.presence
      },
      "metrics" => not_provided_metrics
    }
  end

  def datadog_snapshot
    unless config.datadog_credentials_configured?
      return unconfigured_datadog("Configure DATADOG_API_KEY and DATADOG_APP_KEY before requesting Datadog metrics.")
    end

    metrics = {
      "errorRate" => datadog_metric(config.datadog_error_rate_query, "percent"),
      "responseTime" => datadog_metric(config.datadog_response_time_query, "milliseconds")
    }
    available_count = metrics.values.count { |metric| metric.fetch("state") == "available" }
    error_count = metrics.values.count { |metric| metric.fetch("state") == "error" }
    state = if available_count == metrics.length
      "available"
    elsif available_count.positive?
      "partial"
    elsif error_count.positive?
      "error"
    else
      "unconfigured"
    end

    {
      "provider" => "datadog",
      "source" => "Datadog",
      "state" => state,
      "fetchedAt" => metrics.values.filter_map { |metric| metric["fetchedAt"] }.max,
      "availability" => { "state" => "not_provided", "value" => nil },
      "metrics" => metrics
    }
  end

  def datadog_metric(query, unit)
    return unconfigured_metric(unit, "Set the matching Datadog metric query.") if query.blank?

    response = transport.request(
      method: :post,
      url: "#{config.datadog_api_base_url}/api/v2/metrics/query",
      headers: default_headers.merge(
        "DD-API-KEY" => config.datadog_api_key,
        "DD-APPLICATION-KEY" => config.datadog_app_key
      ),
      json: datadog_request(query)
    )
    raise AdminApiStatusTransport::Error unless success?(response)

    sample = latest_sample(parse_json(response.body))
    return unavailable_metric(unit, "Datadog returned no metric samples.") unless sample

    {
      "state" => "available",
      "value" => sample.fetch(:value),
      "unit" => unit,
      "observedAt" => timestamp_iso8601(sample.fetch(:timestamp)),
      "fetchedAt" => now_iso8601
    }
  rescue AdminApiStatusTransport::Error, JSON::ParserError, TypeError, NoMethodError
    failed_metric(unit, "Datadog metric data could not be retrieved.")
  end

  def datadog_request(query)
    end_time = clock.call.to_i
    {
      "data" => {
        "type" => "timeseries_request",
        "attributes" => {
          "from" => (end_time - config.metrics_window_seconds) * 1000,
          "to" => end_time * 1000,
          "formulas" => [ { "formula" => "query1" } ],
          "queries" => [ {
            "name" => "query1",
            "data_source" => "metrics",
            "query" => query
          } ]
        }
      }
    }
  end

  def latest_sample(payload)
    attributes = payload.dig("data", "attributes")
    return unless attributes.is_a?(Hash)

    samples = time_aligned_samples(attributes["times"], attributes["values"])
    samples = samples_from_values(attributes["values"]) if samples.empty?
    samples.max_by { |sample| sample.fetch(:timestamp) }
  end

  # Datadog v2 returns `times` plus one array of values for each formula. Some
  # compatible responses instead contain [timestamp, value] pairs, so support
  # both shapes without trusting an arbitrary numeric field as a metric value.
  def time_aligned_samples(times, values)
    return [] unless times.is_a?(Array) && values.is_a?(Array)

    series = values.one? && values.first.is_a?(Array) ? values.first : values
    return [] unless series.is_a?(Array)

    times.zip(series).filter_map { |timestamp, value| numeric_sample(timestamp, value) }
  end

  def samples_from_values(values)
    Array(values).flat_map do |entry|
      sample = sample_from(entry)
      sample ? [ sample ] : (entry.is_a?(Array) ? samples_from_values(entry) : [])
    end
  end

  def sample_from(entry)
    case entry
    when Array
      timestamp, value = entry
      return numeric_sample(timestamp, value) if entry.length == 2
    when Hash
      return numeric_sample(entry["timestamp"] || entry["time"], entry["value"])
    end
    nil
  end

  def numeric_sample(timestamp, value)
    timestamp = Float(timestamp, exception: false)
    value = Float(value, exception: false)
    return unless timestamp&.finite? && value&.finite?

    { timestamp:, value: }
  end

  def unconfigured_provider(provider, source, message)
    {
      "provider" => provider,
      "source" => source,
      "state" => "unconfigured",
      "fetchedAt" => nil,
      "availability" => { "state" => "unavailable", "value" => nil },
      "metrics" => not_provided_metrics,
      "issue" => { "code" => "unconfigured", "message" => message }
    }
  end

  def failed_provider(provider, source, message)
    {
      "provider" => provider,
      "source" => source,
      "state" => "error",
      "fetchedAt" => nil,
      "availability" => { "state" => "unavailable", "value" => nil },
      "metrics" => not_provided_metrics,
      "issue" => { "code" => "upstream_error", "message" => message }
    }
  end

  def unconfigured_datadog(message)
    {
      "provider" => "datadog",
      "source" => "Datadog",
      "state" => "unconfigured",
      "fetchedAt" => nil,
      "availability" => { "state" => "not_provided", "value" => nil },
      "metrics" => {
        "errorRate" => unconfigured_metric("percent", message),
        "responseTime" => unconfigured_metric("milliseconds", message)
      },
      "issue" => { "code" => "unconfigured", "message" => message }
    }
  end

  def not_provided_metrics
    {
      "errorRate" => { "state" => "not_provided", "value" => nil, "unit" => "percent" },
      "responseTime" => { "state" => "not_provided", "value" => nil, "unit" => "milliseconds" }
    }
  end

  def unconfigured_metric(unit, message)
    { "state" => "unconfigured", "value" => nil, "unit" => unit, "issue" => { "code" => "unconfigured", "message" => message } }
  end

  def unavailable_metric(unit, message)
    { "state" => "unavailable", "value" => nil, "unit" => unit, "issue" => { "code" => "no_data", "message" => message } }
  end

  def failed_metric(unit, message)
    { "state" => "error", "value" => nil, "unit" => unit, "issue" => { "code" => "upstream_error", "message" => message } }
  end

  def parse_json(body)
    JSON.parse(body)
  end

  def success?(response)
    response.status.between?(200, 299)
  end

  def default_headers
    { "Accept" => "application/json", "User-Agent" => "anabuki-event-admin-status/1.0" }
  end

  def timestamp_iso8601(timestamp)
    seconds = timestamp > 100_000_000_000 ? timestamp / 1000.0 : timestamp
    Time.at(seconds).utc.iso8601
  end

  def now_iso8601
    clock.call.utc.iso8601
  end

  def cache_key
    digest = Digest::SHA256.hexdigest(config.cache_fingerprint)
    "admin-api-status/v1/#{digest}"
  end

  def read_cache
    return if config.cache_ttl_seconds.zero?

    cache.read(cache_key)
  end

  def write_cache(snapshot)
    return if config.cache_ttl_seconds.zero?

    cache.write(cache_key, snapshot, expires_in: config.cache_ttl_seconds)
  end
end
