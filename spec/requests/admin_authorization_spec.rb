require "rails_helper"

RSpec.describe "Management authorization", type: :request do
  SessionFixture = Data.define(:identity, :record, :device, :session_key, :session_cookie_name) do
    def cookie_header(device: self.device, session_key: self.session_key, cookie_name: session_cookie_name)
      {
        "Cookie" => [
          "#{AdminAuth::DEVICE_COOKIE}=#{device}",
          "#{cookie_name}=#{session_key}"
        ].join("; ")
      }
    end
  end

  it "rejects unauthenticated, applicant, and stale management sessions from approval endpoints" do
    get "/api/admin/access-requests"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.fetch("error")).to eq("Authentication is required")

    applicant = build_admin_session("APPLICANT")
    authenticate_as(applicant)
    get "/api/admin/access-requests"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")

    request = pending_request
    post "/api/admin/access-requests/#{request.id}/approve"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")
    expect(request.reload).to be_pending

    stale_management_cookie = build_admin_session("MANAGEMENT_ACCESS")
    authenticate_as(stale_management_cookie)
    post "/api/admin/access-requests/#{request.id}/approve"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")
    expect(request.reload).to be_pending
  end

  it "rejects expired, revoked, and wrong-device cookies from management APIs" do
    expired = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
    expired.record.update!(expires_at: 1.minute.ago)
    revoked = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
    revoked.record.update!(revoked_at: Time.current)
    wrong_device = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)

    [
      [ expired, expired.device ],
      [ revoked, revoked.device ],
      [ wrong_device, SecureRandom.urlsafe_base64(32, false) ]
    ].each do |session, device|
      authenticate_as(session, device:)
      get "/api/admin/allowed-emails"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.fetch("error")).to eq("Authentication is required")
    end
  end

  it "does not let an admin-enabled applicant administer before exchange" do
    applicant = build_admin_session("APPLICANT", admin_enabled: true)
    request = pending_request
    target = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)

    authenticate_as(applicant)
    get "/api/admin/access-requests"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")

    post "/api/admin/access-requests/#{request.id}/approve"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")
    expect(request.reload).to be_pending

    get "/api/admin/allowed-emails"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")

    delete "/api/admin/allowed-emails/#{target.identity.id}"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")
    expect(target.identity.reload).to be_admin_enabled
  end

  it "lets approved management access approve and reject bound applicant requests" do
    manager = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
    approved_request = pending_request
    rejected_request = pending_request

    authenticate_as(manager)
    get "/api/admin/access-requests"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.map { |request| request.fetch("id") }).to contain_exactly(
      approved_request.id,
      rejected_request.id
    )

    post "/api/admin/access-requests/#{approved_request.id}/approve"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("status")).to eq("APPROVED")
    expect(approved_request.reload).to be_approved
    expect(approved_request.applicant_session.admin_identity.reload).to be_admin_enabled

    post "/api/admin/access-requests/#{rejected_request.id}/reject"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("status")).to eq("REJECTED")
    expect(rejected_request.reload).to be_rejected
    expect(rejected_request.applicant_session.admin_identity.reload).not_to be_admin_enabled
  end

  it "enforces a Pundit policy denial before the privileged service" do
    manager = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
    denied_policy = instance_double(AdminAccessRequestPolicy, index?: false)
    allow(AdminAccessRequestPolicy).to receive(:new).and_return(denied_policy)
    expect_any_instance_of(AdminAuth).not_to receive(:pending_access_requests!)

    authenticate_as(manager)
    get "/api/admin/access-requests"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Required permission is missing")
  end

  it "revokes another management identity, its sessions, and pending requests" do
    manager = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
    target = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
    target_applicant = build_admin_session("APPLICANT", identity: target.identity)
    target_request = pending_request_for(target_applicant)

    authenticate_as(manager)
    get "/api/admin/auth/session"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("permissions")).to include("MANAGEMENT_ACCESS_REVOKE")

    delete "/api/admin/allowed-emails/#{target.identity.id}"

    expect(response).to have_http_status(:no_content)
    identity = target.identity.reload
    expect(identity).not_to be_admin_enabled
    expect(identity.revoked_at).to be_present
    expect(identity.admin_device_sessions.count).to eq(2)
    expect(identity.admin_device_sessions.where.not(revoked_at: nil).count).to eq(identity.admin_device_sessions.count)
    expect(target_request.reload).to be_cancelled
    expect(target_request.cancellation_reason).to eq("APPLICANT_SESSION_REVOKED")

    authenticate_as(target)
    get "/api/admin/allowed-emails"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.fetch("error")).to eq("Authentication is required")

    authenticate_as(manager)
    get "/api/admin/allowed-emails"

    expect(response).to have_http_status(:ok)
  end

  it "refuses self-revocation without changing management state" do
    manager = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
    own_applicant = build_admin_session("APPLICANT", identity: manager.identity)
    own_request = pending_request_for(own_applicant)

    authenticate_as(manager)
    delete "/api/admin/allowed-emails/#{manager.identity.id}"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Required permission is missing")
    expect(manager.identity.reload).to be_admin_enabled
    expect(manager.identity.revoked_at).to be_nil
    expect(manager.record.reload.revoked_at).to be_nil
    expect(own_applicant.record.reload.revoked_at).to be_nil
    expect(own_request.reload).to be_pending

    get "/api/admin/allowed-emails"

    expect(response).to have_http_status(:ok)
  end

  it "refuses direct service self-revocation without changing management state" do
    manager = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
    service_cookies = {
      AdminAuth::DEVICE_COOKIE => manager.device,
      AdminAuth::SESSION_COOKIE => manager.session_key
    }
    captured_error = nil

    expect {
      AdminAuth.new(cookies: service_cookies).deactivate_management_access!(manager.identity.id)
    }.to raise_error(AdminAuthError) { |error| captured_error = error }

    expect(captured_error).to have_attributes(
      status: :forbidden,
      message: "Management access cannot be deactivated by its own identity"
    )
    expect(manager.identity.reload).to be_admin_enabled
    expect(manager.identity.revoked_at).to be_nil
    expect(manager.record.reload.revoked_at).to be_nil
  end

  it "does not let management access revoke environment access" do
    with_env("ADMIN_EMAIL_ALLOWLIST" => "environment@example.com") do
      manager = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
      environment = build_admin_session("ENVIRONMENT_ACCESS", email: "environment@example.com")

      authenticate_as(manager)
      delete "/api/admin/allowed-emails/#{environment.identity.id}"

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to eq("Environment management access cannot be deactivated")
      expect(environment.identity.reload).not_to be_admin_enabled
      expect(environment.identity.revoked_at).to be_nil
      expect(environment.record.reload.revoked_at).to be_nil

      authenticate_as(environment)
      get "/api/admin/allowed-emails"

      expect(response).to have_http_status(:ok)
    end
  end

  it "lets environment access revoke another management identity but not itself" do
    with_env("ADMIN_EMAIL_ALLOWLIST" => "environment@example.com") do
      environment = build_admin_session("ENVIRONMENT_ACCESS", email: "environment@example.com")
      target = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)

      authenticate_as(environment)
      delete "/api/admin/allowed-emails/#{target.identity.id}"

      expect(response).to have_http_status(:no_content)
      expect(target.identity.reload).not_to be_admin_enabled

      delete "/api/admin/allowed-emails/#{environment.identity.id}"

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to eq("Required permission is missing")
      expect(environment.record.reload.revoked_at).to be_nil

      get "/api/admin/allowed-emails"

      expect(response).to have_http_status(:ok)
    end
  end

  it "authenticates and authorizes deactivation before resolving its target" do
    missing_identity_id = SecureRandom.uuid

    clear_auth_cookies
    delete "/api/admin/allowed-emails/#{missing_identity_id}"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.fetch("error")).to eq("Authentication is required")

    applicant = build_admin_session("APPLICANT")
    authenticate_as(applicant)
    delete "/api/admin/allowed-emails/#{missing_identity_id}"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")

    manager = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
    authenticate_as(manager)
    delete "/api/admin/allowed-emails/#{missing_identity_id}"

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.fetch("error")).to eq("Not found")
  end

  it "rejects expired and revoked management sessions before deactivation" do
    target = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
    expired = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
    expired.record.update!(expires_at: 1.minute.ago)
    revoked = build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true)
    revoked.record.update!(revoked_at: Time.current)

    [ expired, revoked ].each do |session|
      authenticate_as(session)
      delete "/api/admin/allowed-emails/#{target.identity.id}"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.fetch("error")).to eq("Authentication is required")
      expect(target.identity.reload).to be_admin_enabled
    end
  end

  it "rejects exchange for an unapproved applicant or approval on another device" do
    unapproved = build_admin_session("APPLICANT", admin_enabled: true)
    pending_request_for(unapproved)

    assert_exchange_rejected(unapproved)

    candidate = build_admin_session("APPLICANT", admin_enabled: true)
    approved_on_other_device = build_admin_session("APPLICANT", identity: candidate.identity)
    approved_request_for(approved_on_other_device)

    assert_exchange_rejected(candidate)
  end

  it "exchanges an approved bound applicant cookie and invalidates the old cookie" do
    applicant = build_admin_session("APPLICANT", admin_enabled: true)
    approved_request_for(applicant)

    authenticate_as(applicant)
    post "/api/admin/auth/exchange"

    expect(response).to have_http_status(:no_content)
    expect(applicant.record.reload).to be_management_access
    expect(applicant.record.expires_at).to be_within(1.second).of(3.weeks.from_now)
    expect(cookies[AdminAuth::SESSION_COOKIE]).to be_present
    expect(cookies[AdminAuth::APPLICANT_SESSION_COOKIE]).to be_blank
    expect(Array(response.headers.fetch("Set-Cookie")).join("\n")).to include(
      "#{AdminAuth::SESSION_COOKIE}=",
      "#{AdminAuth::APPLICANT_SESSION_COOKIE}="
    )

    get "/api/admin/allowed-emails"

    expect(response).to have_http_status(:ok)

    replay = ActionDispatch::Integration::Session.new(Rails.application)
    replay.get "/api/admin/allowed-emails", headers: applicant.cookie_header

    expect(replay.response).to have_http_status(:unauthorized)
    expect(replay.response.parsed_body.fetch("error")).to eq("Authentication is required")
  end

  private

  def build_admin_session(source, identity: nil, email: nil, admin_enabled: false)
    suffix = SecureRandom.uuid
    identity ||= AdminIdentity.create!(
      email: email || "#{source.downcase}-#{suffix}@example.com",
      google_sub: "sub-#{suffix}",
      admin_enabled:
    )
    device = SecureRandom.urlsafe_base64(32, false)
    session_key = SecureRandom.urlsafe_base64(32, false)
    record = AdminDeviceSession.create!(
      admin_identity: identity,
      device_id_hash: digest(device),
      session_key_hash: digest(session_key),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: source,
      expires_at: 1.hour.from_now,
      last_seen_at: Time.current
    )
    session_cookie_name = source == "APPLICANT" ? AdminAuth::APPLICANT_SESSION_COOKIE : AdminAuth::SESSION_COOKIE
    SessionFixture.new(identity, record, device, session_key, session_cookie_name)
  end

  def pending_request
    pending_request_for(build_admin_session("APPLICANT"))
  end

  def pending_request_for(applicant)
    access_request_for(applicant, "PENDING")
  end

  def approved_request_for(applicant)
    access_request_for(applicant, "APPROVED", approved_at: Time.current)
  end

  def access_request_for(applicant, status, approved_at: nil)
    AdminAccessRequest.create!(
      email: applicant.identity.email,
      google_sub: applicant.identity.google_sub,
      status:,
      expires_at: applicant.record.expires_at,
      applicant_session: applicant.record,
      applicant_device_id_hash: digest(applicant.device),
      applicant_session_key_hash: digest(applicant.session_key),
      approved_at:
    )
  end

  def authenticate_as(session, device: session.device, session_key: session.session_key)
    clear_auth_cookies
    cookies[AdminAuth::DEVICE_COOKIE] = device
    cookies[session.session_cookie_name] = session_key
  end

  def clear_auth_cookies
    [
      AdminAuth::DEVICE_COOKIE,
      AdminAuth::SESSION_COOKIE,
      AdminAuth::APPLICANT_SESSION_COOKIE
    ].each { |name| cookies.delete(name) }
  end

  def assert_exchange_rejected(applicant)
    authenticate_as(applicant)
    post "/api/admin/auth/exchange"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("The approved applicant session cannot be exchanged")
    expect(applicant.record.reload).to be_applicant

    get "/api/admin/allowed-emails"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")
  end

  def digest(value)
    Digest::SHA256.digest(value)
  end
end
