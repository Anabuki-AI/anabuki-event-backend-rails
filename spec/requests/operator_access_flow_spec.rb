require "rails_helper"

RSpec.describe "Operator management access", type: :request do
  around do |example|
    with_env("PUBLIC_BASE_URL" => "http://localhost:3000") do
      host! "localhost"
      example.run
    end
  end

  # Operator records use the primary database and remain explicit in setup.
  before do
    Operator::DeviceSession.delete_all
    Operator::OauthState.delete_all
    Operator::Identity.delete_all
  end

  it "lists Google-authenticated operator identities and grants and revokes access directly" do
    admin = authenticate_admin
    operator = build_operator_identity

    get "/api/admin/operator-identities"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to contain_exactly(
      "id" => operator.identity.id,
      "email" => operator.identity.email,
      "active" => false,
      "managerEnabled" => false,
      "source" => "MANAGEMENT_ACCESS"
    )

    patch "/api/admin/operator-identities/#{operator.identity.id}", params: { managerEnabled: true }, as: :json,
      headers: { "Origin" => "http://localhost:3000" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => operator.identity.id, "active" => true, "managerEnabled" => true)
    granted_identity = operator.identity.reload
    expect(granted_identity).to have_attributes(manager_enabled: true, granted_by: admin.id, revoked_at: nil)
    expect(granted_identity.granted_at).to be_present

    # An existing applicant cookie becomes usable immediately; a second OAuth
    # session is not required after an administrator grants the identity.
    get "/api/operator/auth/session"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("accessSource" => "MANAGER")

    patch "/api/admin/operator-identities/#{operator.identity.id}", params: { managerEnabled: false }, as: :json,
      headers: { "Origin" => "http://localhost:3000" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("active" => false, "managerEnabled" => false)
    expect(operator.identity.reload).to have_attributes(
      manager_enabled: false,
      granted_by: admin.id,
      granted_at: granted_identity.granted_at
    )
    expect(operator.session.reload.revoked_at).to be_present

    get "/api/operator/auth/session"
    expect(response).to have_http_status(:unauthorized)
  end

  it "requires admin management access and validates UUID and boolean inputs" do
    identity = Operator::Identity.create!(email: "operator@example.com", google_sub: "operator-subject")

    get "/api/admin/operator-identities"
    expect(response).to have_http_status(:unauthorized)

    applicant = build_admin_session("APPLICANT")
    cookies[AdminAuth::DEVICE_COOKIE] = applicant.device
    cookies[AdminAuth::APPLICANT_SESSION_COOKIE] = applicant.session_key
    get "/api/admin/operator-identities"
    expect(response).to have_http_status(:forbidden)

    authenticate_admin
    patch "/api/admin/operator-identities/not-a-uuid", params: { managerEnabled: true }, as: :json
    expect(response).to have_http_status(:bad_request)

    patch "/api/admin/operator-identities/#{identity.id}", params: { managerEnabled: "true" }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(identity.reload).not_to be_manager_enabled
  end

  it "rejects cross-origin operator permission changes" do
    authenticate_admin
    identity = Operator::Identity.create!(email: "operator@example.com", google_sub: "operator-subject")

    patch "/api/admin/operator-identities/#{identity.id}", params: { managerEnabled: true }, as: :json,
      headers: { "Origin" => "https://attacker.example" }

    expect(response).to have_http_status(:forbidden)
    expect(identity.reload).not_to be_manager_enabled
  end

  it "rejects PATCH changes to an identity controlled by the environment allowlist" do
    authenticate_admin
    identity = Operator::Identity.create!(email: "allowlisted@example.com", google_sub: "allowlisted-subject", manager_enabled: true)

    with_env("OPERATOR_EMAIL_ALLOWLIST" => identity.email) do
      patch "/api/admin/operator-identities/#{identity.id}", params: { managerEnabled: false }, as: :json,
        headers: { "Origin" => "http://localhost:3000" }
    end

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "Operator access is controlled by the environment allowlist")
    expect(identity.reload).to be_manager_enabled
  end

  private

  def authenticate_admin
    session = build_admin_session("MANAGEMENT_ACCESS")
    cookies[AdminAuth::DEVICE_COOKIE] = session.device
    cookies[AdminAuth::SESSION_COOKIE] = session.session_key
    session.identity
  end

  def build_admin_session(source)
    identity = AdminIdentity.create!(
      email: "#{source.downcase}-#{SecureRandom.uuid}@example.com",
      google_sub: "admin-sub-#{SecureRandom.uuid}",
      admin_enabled: source != "APPLICANT"
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

  def build_operator_identity
    identity = Operator::Identity.create!(email: "operator@example.com", google_sub: "operator-subject")
    device = SecureRandom.urlsafe_base64(32, false)
    session_key = SecureRandom.urlsafe_base64(32, false)
    session = Operator::DeviceSession.create!(
      operator_identity: identity,
      device_id_hash: Digest::SHA256.digest(device),
      session_key_hash: Digest::SHA256.digest(session_key),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: "APPLICANT",
      expires_at: 20.minutes.from_now,
      last_seen_at: Time.current
    )
    cookies[OperatorAuth::DEVICE_COOKIE] = device
    cookies[OperatorAuth::APPLICANT_SESSION_COOKIE] = session_key
    Data.define(:identity, :session).new(identity, session)
  end
end
