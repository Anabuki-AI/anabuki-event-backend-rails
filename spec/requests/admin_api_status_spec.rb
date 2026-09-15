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

  it "requires a validated management session and reports unconfigured integrations explicitly" do
    with_unconfigured_providers do
      clear_auth_cookies
      get "/api/admin/api-status"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.fetch("error")).to eq("Authentication is required")

      applicant = build_session("APPLICANT")
      authenticate_as(applicant, AdminAuth::APPLICANT_SESSION_COOKIE)
      get "/api/admin/api-status"

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to eq("Management page access is required")

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

  private

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
