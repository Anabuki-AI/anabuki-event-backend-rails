require "rails_helper"

RSpec.describe AdminMonitoring do
  let(:transport) { instance_double(AdminApiStatusTransport) }
  let(:clock) { -> { Time.utc(2025, 9, 1, 12, 0, 0) } }
  let(:fetched_at) { "2025-09-01T12:00:00Z" }

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
      "API_STATUS_CACHE_TTL_SECONDS" => "0"
    }.merge(overrides)
  end

  it "returns exactly one ready source per provider with contract-shaped payloads" do
    allow(transport).to receive(:request) do |method:, url:, headers:, json: nil|
      case url
      when "https://status.example.test/api/v2/summary.json"
        expect(method).to eq(:get)
        expect(headers).not_to have_key("Authorization")
        AdminApiStatusTransport::Response.new(200, {
          "status" => { "indicator" => "major", "description" => "Partial system outage", "updated_at" => "2025-09-01T11:30:00Z" }
        }.to_json)
      when "https://api.datadog.example.test/api/v2/metrics/query"
        expect(method).to eq(:post)
        expect(headers).to include("DD-API-KEY" => "test-api-key", "DD-APPLICATION-KEY" => "test-app-key")
        value = json.dig("data", "attributes", "queries", 0, "query").include?("errors") ? 2.5 : 184.2
        attributes = { "times" => [ 1_756_727_820_000 ], "values" => [ [ value ] ] }
        AdminApiStatusTransport::Response.new(200, { "data" => { "attributes" => attributes } }.to_json)
      else
        raise "Unexpected URL: #{url}"
      end
    end

    result = with_env(provider_env) do
      described_class.new(transport:, clock:).call
    end

    statuspage, datadog = result.fetch("sources")
    expect(result.fetch("sources").map { |source| source.fetch("provider") }).to eq(%w[statuspage datadog])

    expect(statuspage).to eq(
      "provider" => "statuspage",
      "state" => "ready",
      "condition" => "partial_outage",
      "fetchedAt" => fetched_at,
      "updatedAt" => "2025-09-01T11:30:00Z",
      "stale" => false,
      "metrics" => nil
    )

    expect(datadog).to include(
      "provider" => "datadog",
      "state" => "ready",
      "condition" => "unknown",
      "fetchedAt" => fetched_at,
      "updatedAt" => "2025-09-01T11:57:00Z",
      "stale" => false
    )
    expect(datadog.dig("metrics", "errorRatePercent")).to eq(2.5)
    expect(datadog.dig("metrics", "responseTimeMs")).to eq(184.2)
    expect(datadog.dig("metrics", "windowLabel")).to include("average over last 300 seconds")
    expect(result.to_json).not_to include("test-api-key", "test-app-key")
  end

  it "reports both providers as unconfigured without issuing external HTTP requests" do
    expect(transport).not_to receive(:request)

    result = with_env(provider_env(
      "STATUSPAGE_PUBLIC_SUMMARY_URL" => "",
      "DATADOG_API_KEY" => "",
      "DATADOG_APP_KEY" => "",
      "DATADOG_ERROR_RATE_QUERY" => "",
      "DATADOG_RESPONSE_TIME_QUERY" => ""
    )) { described_class.new(transport:, clock:).call }

    expect(result.fetch("sources")).to all(include(
      "state" => "unconfigured",
      "condition" => "unknown",
      "fetchedAt" => nil,
      "updatedAt" => nil,
      "stale" => false
    ))
  end

  it "distinguishes provider authentication and permission failures from generic errors" do
    allow(transport).to receive(:request) do |method:, url:, headers:, json: nil|
      status = if url.include?("status.example.test")
        401
      else
        headers.key?("DD-API-KEY") ? 403 : 500
      end
      AdminApiStatusTransport::Response.new(status, "{}")
    end

    result = with_env(provider_env) { described_class.new(transport:, clock:).call }

    statuspage, datadog = result.fetch("sources")
    expect(statuspage).to include("state" => "unauthenticated", "condition" => "unknown")
    expect(statuspage.fetch("metrics")).to include("errorRatePercent" => nil, "responseTimeMs" => nil, "windowLabel" => nil)
    expect(datadog).to include("state" => "forbidden", "condition" => "unknown")
  end

  it "keeps a Datadog source ready with null metrics when one query has no samples" do
    allow(transport).to receive(:request) do |method:, url:, headers:, json: nil|
      case url
      when "https://status.example.test/api/v2/summary.json"
        AdminApiStatusTransport::Response.new(200, { "status" => { "indicator" => "none" } }.to_json)
      when "https://api.datadog.example.test/api/v2/metrics/query"
        if json.dig("data", "attributes", "queries", 0, "query").include?("errors")
          AdminApiStatusTransport::Response.new(200, { "data" => { "attributes" => { "values" => [ [] ] } } }.to_json)
        else
          attributes = { "values" => [ [ [ 1_756_727_820_000, 120.0 ] ] ] }
          AdminApiStatusTransport::Response.new(200, { "data" => { "attributes" => attributes } }.to_json)
        end
      else
        raise "Unexpected URL: #{url}"
      end
    end

    result = with_env(provider_env) { described_class.new(transport:, clock:).call }

    statuspage, datadog = result.fetch("sources")
    expect(statuspage).to include("state" => "ready", "condition" => "operational", "metrics" => nil)
    expect(datadog).to include("state" => "ready", "stale" => false)
    expect(datadog.dig("metrics", "errorRatePercent")).to be_nil
    expect(datadog.dig("metrics", "responseTimeMs")).to eq(120.0)
    expect(datadog.dig("metrics", "windowLabel")).to be_present
  end

  it "marks the source stale and nulls out-of-range metric values instead of returning them" do
    allow(transport).to receive(:request) do |method:, url:, headers:, json: nil|
      case url
      when "https://status.example.test/api/v2/summary.json"
        AdminApiStatusTransport::Response.new(200, { "status" => { "indicator" => "none" } }.to_json)
      when "https://api.datadog.example.test/api/v2/metrics/query"
        value = json.dig("data", "attributes", "queries", 0, "query").include?("errors") ? 182.5 : 184.2
        attributes = { "values" => [ [ [ 1_756_727_820_000, value ] ] ] }
        AdminApiStatusTransport::Response.new(200, { "data" => { "attributes" => attributes } }.to_json)
      else
        raise "Unexpected URL: #{url}"
      end
    end

    result = with_env(provider_env) { described_class.new(transport:, clock:).call }

    datadog = result.fetch("sources").last
    expect(datadog).to include("state" => "ready", "stale" => true)
    expect(datadog.dig("metrics", "errorRatePercent")).to be_nil
    expect(datadog.dig("metrics", "responseTimeMs")).to eq(184.2)
  end

  it "falls back to the fetch time for updatedAt when the provider omits it, keeping ready timestamps present" do
    allow(transport).to receive(:request) do |method:, url:, headers:, json: nil|
      raise NotImplementedError unless url == "https://status.example.test/api/v2/summary.json"

      AdminApiStatusTransport::Response.new(200, { "status" => { "indicator" => "minor" } }.to_json)
    end

    result = with_env(provider_env(
      "DATADOG_API_KEY" => "test-api-key",
      "DATADOG_APP_KEY" => "test-app-key",
      "DATADOG_ERROR_RATE_QUERY" => "",
      "DATADOG_RESPONSE_TIME_QUERY" => ""
    )) { described_class.new(transport:, clock:).call }

    statuspage, datadog = result.fetch("sources")
    expect(statuspage).to include("state" => "ready", "condition" => "degraded", "updatedAt" => fetched_at)
    expect(datadog).to include("state" => "unconfigured")
  end
end
