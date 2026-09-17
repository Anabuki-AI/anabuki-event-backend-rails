# Produces the external-monitoring snapshot for GET /api/admin/monitoring,
# following frontend/docs/admin-monitoring-contract.md in the frontend
# repository. Each known provider is always present exactly once, even when it
# is unconfigured or failing. Provider credentials and upstream errors stay
# server-side: the payload carries only normalized states, conditions, and
# metrics, and never API keys, upstream response bodies, or private URLs.
class AdminMonitoring
  SOURCES = %w[statuspage datadog].freeze
  ERROR_RATE_RANGE = 0.0..100.0

  STATUSPAGE_INDICATORS = {
    "none" => "operational",
    "minor" => "degraded",
    "major" => "partial_outage",
    "critical" => "major_outage"
  }.freeze

  def initialize(config: AdminApiStatusConfig.new, transport: AdminApiStatusTransport.new, clock: -> { Time.current })
    @config = config
    @transport = transport
    @clock = clock
  end

  def call
    { "sources" => [ statuspage_source, datadog_source ] }
  end

  private

  attr_reader :config, :transport, :clock

  # ---- Statuspage -------------------------------------------------------

  def statuspage_source
    if config.statuspage_public_configured?
      statuspage_from_public_summary
    elsif config.statuspage_authenticated_configured?
      statuspage_from_authenticated_page
    else
      unconfigured_source("statuspage")
    end
  end

  def statuspage_from_public_summary
    response = transport.request(
      method: :get,
      url: config.statuspage_public_summary_url,
      headers: default_headers
    )
    return provider_state_failure("statuspage", response.status) unless success?(response)

    body = parse_json(response.body)
    status = body.fetch("status")
    ready_source(
      provider: "statuspage",
      condition: STATUSPAGE_INDICATORS.fetch(status.fetch("indicator").to_s, "unknown"),
      updated_at: timestamp_or_fetched(status["updated_at"]),
      metrics: nil
    )
  rescue AdminApiStatusTransport::Error, JSON::ParserError, KeyError, TypeError, NoMethodError
    error_source("statuspage")
  end

  def statuspage_from_authenticated_page
    page_id = URI.encode_www_form_component(config.statuspage_page_id)
    response = transport.request(
      method: :get,
      url: "#{config.statuspage_api_base_url}/pages/#{page_id}",
      headers: default_headers.merge("Authorization" => "OAuth #{config.statuspage_api_key}")
    )
    return provider_state_failure("statuspage", response.status) unless success?(response)

    body = parse_json(response.body)
    ready_source(
      provider: "statuspage",
      condition: STATUSPAGE_INDICATORS.fetch(body.fetch("status_indicator").to_s, "unknown"),
      updated_at: timestamp_or_fetched(body["updated_at"]),
      metrics: nil
    )
  rescue AdminApiStatusTransport::Error, JSON::ParserError, KeyError, TypeError, NoMethodError
    error_source("statuspage")
  end

  # ---- Datadog ----------------------------------------------------------

  def datadog_source
    return unconfigured_source("datadog") unless config.datadog_credentials_configured?
    return unconfigured_source("datadog") unless datadog_queries_configured?

    error_rate = query_datadog_metric(config.datadog_error_rate_query, range: ERROR_RATE_RANGE)
    response_time = query_datadog_metric(config.datadog_response_time_query, range: 0.0..)
    states = [ error_rate[:state], response_time[:state] ]
    return state_source("datadog", "unauthenticated") if states.include?(:unauthenticated)
    return state_source("datadog", "forbidden") if states.include?(:forbidden)
    if error_rate[:state] == :failed && response_time[:state] == :failed
      return error_source("datadog")
    end

    invalid = [ error_rate, response_time ].any? { |metric| metric[:state] == :invalid }
    has_metric = [ error_rate[:value], response_time[:value] ].any? { |value| value.is_a?(Numeric) }
    ready_source(
      provider: "datadog",
      condition: "unknown",
      updated_at: [ error_rate, response_time ].filter_map { |metric| metric[:observed_at] }.max,
      metrics: {
        "errorRatePercent" => bounded_percent(error_rate[:value]),
        "responseTimeMs" => non_negative_ms(response_time[:value]),
        "windowLabel" => has_metric ? "average over last #{config.metrics_window_seconds} seconds (Datadog metrics query)" : nil
      },
      stale: invalid || false
    )
  end

  def datadog_queries_configured?
    config.datadog_error_rate_query.present? || config.datadog_response_time_query.present?
  end

  # Returns {state:, value:, observed_at:}. A single failed query does not fail
  # the source: it only yields a null metric. Provider-level 401/403 and values
  # outside the contract's documented ranges surface as distinct states: 401/403
  # fail the source as unauthenticated/forbidden; invalid values return null and
  # mark the source stale instead of being returned as numbers.
  def query_datadog_metric(query, range:)
    return { state: :absent, value: nil, observed_at: nil } if query.blank?

    response = transport.request(
      method: :post,
      url: "#{config.datadog_api_base_url}/api/v2/metrics/query",
      headers: default_headers.merge(
        "DD-API-KEY" => config.datadog_api_key,
        "DD-APPLICATION-KEY" => config.datadog_app_key
      ),
      json: datadog_request(query)
    )
    return { state: :unauthenticated, value: nil, observed_at: nil } if response.status == 401
    return { state: :forbidden, value: nil, observed_at: nil } if response.status == 403
    return { state: :failed, value: nil, observed_at: nil } unless success?(response)

    sample = latest_sample(parse_json(response.body))
    return { state: :failed, value: nil, observed_at: nil } unless sample

    value = sample.fetch(:value)
    state = value.finite? && range.cover?(value) ? :available : :invalid
    { state:, value:, observed_at: timestamp_iso8601(sample.fetch(:timestamp)) }
  rescue AdminApiStatusTransport::Error, JSON::ParserError, TypeError, NoMethodError
    { state: :failed, value: nil, observed_at: nil }
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

  # Datadog v2 returns `times` plus one array of values per formula; some
  # compatible responses instead carry [timestamp, value] pairs. Support both
  # shapes without trusting an arbitrary numeric field as a metric value.
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

  # ---- Shared source shapes ---------------------------------------------

  def ready_source(provider:, condition:, updated_at:, metrics:, stale: false)
    {
      "provider" => provider,
      "state" => "ready",
      "condition" => condition,
      "fetchedAt" => now_iso8601,
      "updatedAt" => updated_at,
      "stale" => stale,
      "metrics" => metrics
    }
  end

  def unconfigured_source(provider)
    {
      "provider" => provider,
      "state" => "unconfigured",
      "condition" => "unknown",
      "fetchedAt" => nil,
      "updatedAt" => nil,
      "stale" => false,
      "metrics" => null_metrics
    }
  end

  def error_source(provider)
    {
      "provider" => provider,
      "state" => "error",
      "condition" => "unknown",
      "fetchedAt" => nil,
      "updatedAt" => nil,
      "stale" => false,
      "metrics" => null_metrics
    }
  end

  # Provider-level 401/403 are distinguished from configuration gaps and from
  # generic failures, as the contract's transport/provider state table demands.
  def provider_state_failure(provider, status)
    case status
    when 401 then state_source(provider, "unauthenticated")
    when 403 then state_source(provider, "forbidden")
    else error_source(provider)
    end
  end

  def state_source(provider, state)
    {
      "provider" => provider,
      "state" => state,
      "condition" => "unknown",
      "fetchedAt" => nil,
      "updatedAt" => nil,
      "stale" => false,
      "metrics" => null_metrics
    }
  end

  def null_metrics
    {
      "errorRatePercent" => nil,
      "responseTimeMs" => nil,
      "windowLabel" => nil
    }
  end

  def bounded_percent(value)
    return nil unless value && ERROR_RATE_RANGE.cover?(value)

    value
  end

  def non_negative_ms(value)
    return nil unless value && value >= 0

    value
  end

  def timestamp_or_fetched(provider_timestamp)
    parsed = provider_timestamp.is_a?(String) ? Time.iso8601(provider_timestamp) : nil
    parsed&.utc&.iso8601 || now_iso8601
  rescue ArgumentError
    now_iso8601
  end

  def timestamp_iso8601(timestamp)
    seconds = timestamp > 100_000_000_000 ? timestamp / 1000.0 : timestamp
    Time.at(seconds).utc.iso8601
  end

  def now_iso8601
    clock.call.utc.iso8601
  end

  def parse_json(body)
    JSON.parse(body)
  end

  def success?(response)
    response.status.between?(200, 299)
  end

  def default_headers
    { "Accept" => "application/json", "User-Agent" => "anabuki-event-admin-monitoring/1.0" }
  end
end
