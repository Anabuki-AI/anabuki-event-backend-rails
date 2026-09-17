require "rails_helper"

RSpec.describe AdminApiStatus do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:transport) { instance_double(AdminApiStatusTransport) }
  let(:clock) { -> { Time.utc(2025, 9, 1, 12, 0, 0) } }

  def provider_env(overrides = {})
    {
      "STATUSPAGE_PUBLIC_SUMMARY_URL" => "https://status.example.test/api/v2/summary.json",
      "STATUSPAGE_PAGE_ID" => "",
      "STATUSPAGE_API_KEY" => "",
      "STATUSPAGE_API_BASE_URL" => "https://api.statuspage.io/v1",
      "DATADOG_API_KEY" => "test-api-key",
      "DATADOG_APP_KEY" => "test-app-key",
      "DATADOG_SITE" => "datadoghq.com",
      "DATADOG_API_BASE_URL" => "https://api.datadog.example.test",
      "DATADOG_ERROR_RATE_QUERY" => "avg:quiz.errors{env:test}",
      "DATADOG_RESPONSE_TIME_QUERY" => "avg:quiz.response_time{env:test}",
      "DATADOG_METRICS_WINDOW_SECONDS" => "300",
      "API_STATUS_CACHE_TTL_SECONDS" => "60"
    }.merge(overrides)
  end

  it "normalizes public Statuspage and Datadog v2 Metrics API responses without exposing credentials" do
    datadog_requests = []
    allow(transport).to receive(:request) do |method:, url:, headers:, json: nil|
      case url
      when "https://status.example.test/api/v2/summary.json"
        expect(method).to eq(:get)
        expect(headers).not_to have_key("Authorization")
        AdminApiStatusTransport::Response.new(200, {
          "status" => { "indicator" => "minor", "description" => "Minor service disruption" }
        }.to_json)
      when "https://api.datadog.example.test/api/v2/metrics/query"
        expect(method).to eq(:post)
        expect(headers).to include("DD-API-KEY" => "test-api-key", "DD-APPLICATION-KEY" => "test-app-key")
        datadog_requests << json
        value = datadog_requests.length == 1 ? 2.5 : 184.2
        attributes = if datadog_requests.length == 1
          { "values" => [ [ 1_756_728_000_000, value ] ] }
        else
          { "times" => [ 1_756_728_000_000 ], "values" => [ [ value ] ] }
        end
        AdminApiStatusTransport::Response.new(200, { "data" => { "attributes" => attributes } }.to_json)
      else
        raise "Unexpected URL: #{url}"
      end
    end

    result = with_env(provider_env) do
      described_class.new(cache:, transport:, clock:).call
    end

    statuspage, datadog = result.fetch("providers")
    expect(result).to include("generatedAt" => "2025-09-01T12:00:00Z", "cached" => false)
    expect(statuspage).to include(
      "provider" => "statuspage",
      "state" => "available",
      "fetchedAt" => "2025-09-01T12:00:00Z"
    )
    expect(statuspage.dig("availability", "value")).to eq("degraded")
    expect(datadog).to include("provider" => "datadog", "state" => "available")
    expect(datadog.dig("metrics", "errorRate")).to include("state" => "available", "value" => 2.5, "unit" => "percent")
    expect(datadog.dig("metrics", "responseTime")).to include("state" => "available", "value" => 184.2, "unit" => "milliseconds")
    expect(datadog_requests.map { |request| request.dig("data", "attributes", "queries", 0, "query") }).to contain_exactly(
      "avg:quiz.errors{env:test}",
      "avg:quiz.response_time{env:test}"
    )
    expect(result.to_json).not_to include("test-api-key", "test-app-key")
  end

  it "returns unconfigured providers without issuing external HTTP requests" do
    expect(transport).not_to receive(:request)

    result = with_env(provider_env(
      "STATUSPAGE_PUBLIC_SUMMARY_URL" => "",
      "DATADOG_API_KEY" => "",
      "DATADOG_APP_KEY" => "",
      "DATADOG_ERROR_RATE_QUERY" => "",
      "DATADOG_RESPONSE_TIME_QUERY" => ""
    )) do
      described_class.new(cache:, transport:, clock:).call
    end

    expect(result.fetch("providers").map { |provider| provider.fetch("state") }).to eq(%w[unconfigured unconfigured])
    expect(result.dig("providers", 0, "availability", "state")).to eq("unavailable")
    expect(result.dig("providers", 1, "metrics", "errorRate", "state")).to eq("unconfigured")
  end

  it "returns a generic upstream error rather than an external exception" do
    allow(transport).to receive(:request).and_raise(AdminApiStatusTransport::Error, "connection refused")

    result = with_env(provider_env(
      "DATADOG_API_KEY" => "",
      "DATADOG_APP_KEY" => "",
      "DATADOG_ERROR_RATE_QUERY" => "",
      "DATADOG_RESPONSE_TIME_QUERY" => ""
    )) do
      described_class.new(cache:, transport:, clock:).call
    end

    statuspage = result.fetch("providers").first
    expect(statuspage).to include("state" => "error", "fetchedAt" => nil)
    expect(statuspage.fetch("issue")).to eq(
      "code" => "upstream_error",
      "message" => "Statuspage data could not be retrieved."
    )
    expect(statuspage.to_json).not_to include("connection refused")
  end

  it "keeps Datadog unconfigured when both configured metric queries have no samples" do
    no_samples = AdminApiStatusTransport::Response.new(200, {
      "data" => { "attributes" => { "values" => [ [] ] } }
    }.to_json)
    allow(transport).to receive(:request) do |url:, **|
      case url
      when "https://status.example.test/api/v2/summary.json"
        AdminApiStatusTransport::Response.new(200, {
          "status" => { "indicator" => "none", "description" => "All systems operational" }
        }.to_json)
      when "https://api.datadog.example.test/api/v2/metrics/query"
        no_samples
      else
        raise "Unexpected URL: #{url}"
      end
    end

    result = with_env(provider_env) do
      described_class.new(cache:, transport:, clock:).call
    end

    datadog = result.fetch("providers").last
    # Compatibility behavior pending provider-state contract agreement: use the
    # metric states below rather than treating this aggregate as configuration proof.
    expect(datadog).to include("state" => "unconfigured", "fetchedAt" => nil)
    expect(datadog.dig("metrics", "errorRate")).to include(
      "state" => "unavailable",
      "value" => nil,
      "issue" => include("code" => "no_data")
    )
    expect(datadog.dig("metrics", "responseTime")).to include(
      "state" => "unavailable",
      "value" => nil,
      "issue" => include("code" => "no_data")
    )
  end

  it "passes through finite Datadog values outside their semantic ranges" do
    values = [ 101.0, -1.0 ]
    allow(transport).to receive(:request) do |url:, **|
      case url
      when "https://status.example.test/api/v2/summary.json"
        AdminApiStatusTransport::Response.new(200, {
          "status" => { "indicator" => "none", "description" => "All systems operational" }
        }.to_json)
      when "https://api.datadog.example.test/api/v2/metrics/query"
        AdminApiStatusTransport::Response.new(200, {
          "data" => { "attributes" => { "times" => [ 1_756_728_000_000 ], "values" => [ [ values.shift ] ] } }
        }.to_json)
      else
        raise "Unexpected URL: #{url}"
      end
    end

    result = with_env(provider_env) do
      described_class.new(cache:, transport:, clock:).call
    end

    datadog = result.fetch("providers").last
    # TODO: agree whether future contract revisions reject or classify invalid
    # percentages and negative durations; do not silently clamp these values.
    expect(datadog).to include("state" => "available")
    expect(datadog.dig("metrics", "errorRate")).to include("state" => "available", "value" => 101.0)
    expect(datadog.dig("metrics", "responseTime")).to include("state" => "available", "value" => -1.0)
  end

  it "caches a provider snapshot server-side while marking subsequent results as cached" do
    response = AdminApiStatusTransport::Response.new(200, {
      "status" => { "indicator" => "none", "description" => "All systems operational" }
    }.to_json)
    expect(transport).to receive(:request).once.and_return(response)

    first, second = with_env(provider_env(
      "DATADOG_API_KEY" => "",
      "DATADOG_APP_KEY" => "",
      "DATADOG_ERROR_RATE_QUERY" => "",
      "DATADOG_RESPONSE_TIME_QUERY" => ""
    )) do
      service = described_class.new(cache:, transport:, clock:)
      [ service.call, service.call ]
    end

    expect(first.fetch("cached")).to be(false)
    expect(second.fetch("cached")).to be(true)
    expect(second.fetch("generatedAt")).to eq(first.fetch("generatedAt"))
  end
end
