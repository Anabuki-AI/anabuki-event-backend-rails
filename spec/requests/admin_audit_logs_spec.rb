require "rails_helper"

RSpec.describe "Admin audit logs API", type: :request do
  around do |example|
    host! "localhost"
    example.run
  end

  let(:manager) { build_session("MANAGEMENT_ACCESS", admin_enabled: true) }

  before do
    authenticate_as(manager)
  end

  it "requires a management session with MANAGEMENT_PAGE_VIEW" do
    clear_auth_cookies
    get "/api/admin/audit-logs"
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.fetch("error")).to eq("Authentication is required")

    authenticate_as(build_session("APPLICANT"), AdminAuth::APPLICANT_SESSION_COOKIE)
    get "/api/admin/audit-logs"
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")

    applicant_policy = instance_double(AuditLogPolicy, index?: false)
    allow(AuditLogPolicy).to receive(:new).and_return(applicant_policy)
    authenticate_as(manager)
    get "/api/admin/audit-logs"
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Required permission is missing")
  end

  it "returns entries newest-first with paging metadata and no-store" do
    base = Time.current
    newest = create_entry("QUESTION_CREATED", occurred_at: base + 2.seconds)
    middle = create_entry("ADMIN_LOGGED_OUT", occurred_at: base + 1.second)
    oldest = create_entry("QUESTION_DELETED", occurred_at: base)

    get "/api/admin/audit-logs", params: { page: 1, perPage: 2 }

    expect(response).to have_http_status(:ok)
    expect(response.headers.fetch("Cache-Control")).to eq("no-store")
    body = response.parsed_body
    expect(body.fetch("page")).to eq(1)
    expect(body.fetch("perPage")).to eq(2)
    expect(body.fetch("totalEntries")).to eq(3)
    expect(body.fetch("entries").map { |entry| entry.fetch("id") }).to eq([ newest.id.to_s, middle.id.to_s ])
    expect(body.dig("entries", 0)).to include(
      "type" => "QUESTION_CREATED",
      "actorEmail" => manager.identity.email,
      "actorGoogleSub" => manager.identity.google_sub,
      "targetType" => "QUESTION"
    )
    expect(body.dig("entries", 0).fetch("occurredAt")).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})\z/)
    expect(body.dig("entries", 0).fetch("detail")).to eq("questionId" => 1)

    get "/api/admin/audit-logs", params: { page: 2, perPage: 2 }
    expect(response.parsed_body.fetch("entries").map { |entry| entry.fetch("id") }).to eq([ oldest.id.to_s ])
  end

  it "paginates with offset and echoes the requested page" do
    3.times { create_entry("ADMIN_LOGGED_OUT") }

    get "/api/admin/audit-logs", params: { page: 2, perPage: 2 }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.fetch("entries").length).to eq(1)
    expect(body.fetch("page")).to eq(2)
    expect(body.fetch("totalEntries")).to eq(3)
  end

  it "orders ties on occurred_at by descending id" do
    first = create_entry("ADMIN_LOGGED_OUT", occurred_at: Time.current)
    second = create_entry("ADMIN_LOGGED_OUT", occurred_at: first.occurred_at)

    get "/api/admin/audit-logs"
    expect(response.parsed_body.fetch("entries").map { |entry| entry.fetch("id") }).to eq([ second.id.to_s, first.id.to_s ])
  end

  it "filters by a comma-separated type subset and rejects unknown types" do
    created = create_entry("QUESTION_CREATED")
    create_entry("ADMIN_LOGGED_OUT")

    get "/api/admin/audit-logs", params: { type: "QUESTION_CREATED,QUESTION_DELETED" }

    expect(response).to have_http_status(:ok)
    entries = response.parsed_body.fetch("entries")
    expect(entries.length).to eq(1)
    expect(entries.first.fetch("id")).to eq(created.id.to_s)
    expect(response.parsed_body.fetch("totalEntries")).to eq(1)

    get "/api/admin/audit-logs", params: { type: "QUESTION_DELETED,NOT_A_REAL_TYPE" }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error")).to include("type").and include("NOT_A_REAL_TYPE")
  end

  it "filters by an inclusive RFC3339 from/to window" do
    boundary = Time.utc(2025, 9, 1, 9, 0, 0)
    outside = create_entry("ADMIN_LOGGED_OUT", occurred_at: boundary - 1.second)
    inside = create_entry("QUESTION_CREATED", occurred_at: boundary)

    get "/api/admin/audit-logs", params: { from: "2025-09-01T09:00:00Z", to: "2025-09-01T09:00:05Z" }

    expect(response).to have_http_status(:ok)
    ids = response.parsed_body.fetch("entries").map { |entry| entry.fetch("id") }
    expect(ids).to eq([ inside.id.to_s ])
    expect(ids).not_to include(outside.id.to_s)

    get "/api/admin/audit-logs", params: { from: "2025-09-01T09:00:00Z", to: "2025-09-01T08:59:00Z" }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error")).to include("from")

    get "/api/admin/audit-logs", params: { from: "2025-09-01" }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error")).to include("from")
  end

  it "rejects invalid page and perPage values naming the offending parameter" do
    get "/api/admin/audit-logs", params: { page: 0 }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error")).to include("page")

    get "/api/admin/audit-logs", params: { page: "abc" }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error")).to include("page")

    get "/api/admin/audit-logs", params: { perPage: 0 }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error")).to include("perPage")

    get "/api/admin/audit-logs", params: { perPage: 101 }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error")).to include("perPage")

    get "/api/admin/audit-logs", params: { perPage: 100 }
    expect(response).to have_http_status(:ok)
  end

  it "distinguishes an empty successful result from errors" do
    get "/api/admin/audit-logs"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("entries")).to eq([])
    expect(response.parsed_body.fetch("totalEntries")).to eq(0)
  end

  private

  def authenticate_as(session, cookie_name = AdminAuth::SESSION_COOKIE)
    clear_auth_cookies
    cookies[AdminAuth::DEVICE_COOKIE] = session.device
    cookies[cookie_name] = session.session_key
  end

  def clear_auth_cookies
    [ AdminAuth::DEVICE_COOKIE, AdminAuth::SESSION_COOKIE, AdminAuth::APPLICANT_SESSION_COOKIE ].each do |name|
      cookies.delete(name)
    end
  end

  def create_entry(type, occurred_at: Time.current)
    AuditLog.create!(
      event_type: type,
      admin_identity: manager.identity,
      actor_email: manager.identity.email,
      actor_google_sub: manager.identity.google_sub,
      target_type: type.start_with?("QUESTION") ? "QUESTION" : nil,
      target_id: type.start_with?("QUESTION") ? "1" : nil,
      detail: type.start_with?("QUESTION") ? { "questionId" => 1 } : {},
      occurred_at:
    )
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
    Data.define(:identity, :device, :session_key).new(identity, device, session_key)
  end
end
