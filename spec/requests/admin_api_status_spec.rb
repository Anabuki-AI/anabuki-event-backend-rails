require "rails_helper"

RSpec.describe "Admin API status", type: :request do
  around do |example|
    host! "localhost"
    example.run
  end

  ApiStatusSessionFixture = Data.define(:identity, :device, :session_key) do
    def cookie_header
      [
        "#{AdminAuth::DEVICE_COOKIE}=#{device}",
        "#{AdminAuth::SESSION_COOKIE}=#{session_key}"
      ].join("; ")
    end
  end

  it "returns 401 without a validated management session" do
    clear_auth_cookies
    get "/api/admin/api-status"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.fetch("error")).to eq("Authentication is required")
  end

  it "returns 403 for an applicant session" do
    applicant = build_session("APPLICANT")
    authenticate_as(applicant, AdminAuth::APPLICANT_SESSION_COOKIE)
    get "/api/admin/api-status"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")
  end

  it "reports unconfigured integrations explicitly to a management session" do
    with_unconfigured_providers do
      manager = build_session("MANAGEMENT_ACCESS", admin_enabled: true)
      authenticate_as(manager, AdminAuth::SESSION_COOKIE)
      get "/api/admin/api-status"

      expect(response).to have_http_status(:ok)
      expect(response.headers.fetch("Cache-Control")).to eq("no-store")
      expect(response.parsed_body.fetch("providers")).to all(include("state" => "unconfigured"))
    end
  end

  it "enforces the API-status Pundit policy before requesting provider data" do
    manager = build_session("MANAGEMENT_ACCESS", admin_enabled: true)
    denied_policy = instance_double(AdminApiStatusPolicy, show?: false)
    allow(AdminApiStatusPolicy).to receive(:new).and_return(denied_policy)
    expect_any_instance_of(AdminApiStatus).not_to receive(:call)

    authenticate_as(manager, AdminAuth::SESSION_COOKIE)
    get "/api/admin/api-status"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Required permission is missing")
  end

  it "isolates TLS failures, preserves the response contract, and caches the generic provider error" do
    tls_message = "certificate verify failed: private test certificate"
    cache = ActiveSupport::Cache::MemoryStore.new
    statuspage_http = double("Statuspage HTTP")
    datadog_http = double("Datadog HTTP")
    [ statuspage_http, datadog_http ].each do |http|
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:write_timeout=)
    end
    allow(Rails).to receive(:cache).and_return(cache)
    allow(Net::HTTP).to receive(:new) do |host, _port|
      case host
      when "status.example.test" then statuspage_http
      when "api.datadog.example.test" then datadog_http
      else raise "Unexpected HTTP host: #{host}"
      end
    end
    expect(statuspage_http).to receive(:request).once.and_raise(OpenSSL::SSL::SSLError, tls_message)
    expect(datadog_http).to receive(:request).twice.and_return(
      http_response(200, "data" => { "attributes" => { "times" => [ 1_756_728_000_000 ], "values" => [ [ 2.5 ] ] } }),
      http_response(200, "data" => { "attributes" => { "times" => [ 1_756_728_000_000 ], "values" => [ [ 184.2 ] ] } })
    )

    with_configured_providers do
      manager = build_session("MANAGEMENT_ACCESS", admin_enabled: true)
      authenticate_as(manager, AdminAuth::SESSION_COOKIE)

      get "/api/admin/api-status"
      first = response.parsed_body

      expect(response).to have_http_status(:ok)
      expect(response.headers.fetch("Cache-Control")).to eq("no-store")
      expect(first.keys).to contain_exactly("generatedAt", "cached", "providers")
      expect(first.fetch("cached")).to be(false)
      expect(first.fetch("providers")).to be_an(Array)
      expect(first.fetch("providers").map { |provider| provider.fetch("provider") }).to eq(%w[statuspage datadog])

      statuspage, datadog = first.fetch("providers")
      expect(statuspage).to include("state" => "error", "fetchedAt" => nil)
      expect(statuspage.fetch("issue")).to eq(
        "code" => "upstream_error",
        "message" => "Statuspage data could not be retrieved."
      )
      expect(first.to_json).not_to include(tls_message)
      expect(datadog).to include("state" => "available")
      expect(datadog.dig("metrics", "errorRate")).to include("state" => "available", "value" => 2.5)
      expect(datadog.dig("metrics", "responseTime")).to include("state" => "available", "value" => 184.2)

      get "/api/admin/api-status"
      second = response.parsed_body

      expect(response).to have_http_status(:ok)
      expect(response.headers.fetch("Cache-Control")).to eq("no-store")
      expect(second).to include("cached" => true, "generatedAt" => first.fetch("generatedAt"))
      expect(second.keys).to contain_exactly("generatedAt", "cached", "providers")
    end
  end

  private

  def with_configured_providers(&block)
    with_env(
      "STATUSPAGE_PUBLIC_SUMMARY_URL" => "https://status.example.test/api/v2/summary.json",
      "STATUSPAGE_PAGE_ID" => "",
      "STATUSPAGE_API_KEY" => "",
      "DATADOG_API_KEY" => "test-api-key",
      "DATADOG_APP_KEY" => "test-app-key",
      "DATADOG_API_BASE_URL" => "https://api.datadog.example.test",
      "DATADOG_ERROR_RATE_QUERY" => "avg:quiz.errors{env:test}",
      "DATADOG_RESPONSE_TIME_QUERY" => "avg:quiz.response_time{env:test}",
      "API_STATUS_CACHE_TTL_SECONDS" => "60",
      &block
    )
  end

  def http_response(status, body)
    Struct.new(:code, :body).new(status.to_s, body.to_json)
  end

  def with_unconfigured_providers(&block)
    with_env(
      "STATUSPAGE_PUBLIC_SUMMARY_URL" => "",
      "STATUSPAGE_PAGE_ID" => "",
      "STATUSPAGE_API_KEY" => "",
      "DATADOG_API_KEY" => "",
      "DATADOG_APP_KEY" => "",
      "DATADOG_ERROR_RATE_QUERY" => "",
      "DATADOG_RESPONSE_TIME_QUERY" => "",
      "API_STATUS_CACHE_TTL_SECONDS" => "0",
      &block
    )
  end

  def authenticate_as(session, cookie_name)
    clear_auth_cookies
    cookies[AdminAuth::DEVICE_COOKIE] = session.device
    cookies[cookie_name] = session.session_key
  end

  def clear_auth_cookies
    [ AdminAuth::DEVICE_COOKIE, AdminAuth::SESSION_COOKIE, AdminAuth::APPLICANT_SESSION_COOKIE ].each do |name|
      cookies.delete(name)
    end
  end

  def build_session(source, admin_enabled: false)
    suffix = SecureRandom.uuid
    identity = AdminIdentity.create!(
      email: "#{source.downcase}-#{suffix}@example.com",
      google_sub: "sub-#{suffix}",
      admin_enabled:
    )
    device = SecureRandom.urlsafe_base64(32, false)
    session_key = SecureRandom.urlsafe_base64(32, false)
    AdminDeviceSession.create!(
      admin_identity: identity,
      device_id_hash: Digest::SHA256.digest(device),
      session_key_hash: Digest::SHA256.digest(session_key),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: source,
      expires_at: 1.hour.from_now,
      last_seen_at: Time.current
    )
    ApiStatusSessionFixture.new(identity, device, session_key)
  end
end
