require "rails_helper"

# Verifies that succeeded admin actions append the contract's audit-log events.
RSpec.describe "Admin audit trail hooks", type: :request do
  around do |example|
    host! "localhost"
    example.run
  end

  let(:manager) { build_admin_session("MANAGEMENT_ACCESS", admin_enabled: true) }

  before do
    authenticate_admin_as(manager)
  end

  it "records QUESTION_CREATED, QUESTION_UPDATED, and QUESTION_DELETED" do
    post "/api/admin/questions", params: question_payload, as: :json
    expect(response).to have_http_status(:created)
    question_id = response.parsed_body.fetch("id").to_s

    put "/api/admin/questions/#{question_id}", params: question_payload(question_text: "更新後"), as: :json
    expect(response).to have_http_status(:ok)

    delete "/api/admin/questions/#{question_id}", headers: { "X-Requested-With" => "test" }
    expect(response).to have_http_status(:no_content)

    types = AuditLog.order(:id).pluck(:event_type)
    expect(types).to eq([ "QUESTION_CREATED", "QUESTION_UPDATED", "QUESTION_DELETED" ])
    created = AuditLog.find_by(event_type: "QUESTION_CREATED")
    expect(created).to have_attributes(
      admin_identity_id: manager.identity.id,
      actor_email: manager.identity.email,
      target_type: "QUESTION",
      target_id: question_id
    )
    expect(created.detail).to include("position" => 1)
    expect(AuditLog.find_by(event_type: "QUESTION_DELETED").detail).to eq({})
  end

  it "records CONFIDENCE_MULTIPLIER_UPDATED" do
    patch "/api/admin/confidence-multipliers/high", params: { confidenceMultiplier: 1.5 }, as: :json
    expect(response).to have_http_status(:ok)

    entry = AuditLog.find_by(event_type: "CONFIDENCE_MULTIPLIER_UPDATED")
    expect(entry).to have_attributes(target_type: "CONFIDENCE_MULTIPLIER", target_id: "high", actor_email: manager.identity.email)
    expect(entry.detail).to include("level" => "high", "confidenceMultiplier" => 1.5)
  end

  it "records ADMIN_LOGIN_SUCCEEDED when a management session is issued" do
    identity = AdminIdentity.create!(email: "manager-oauth@example.com", google_sub: "manager-oauth-sub", admin_enabled: true)
    with_env(
      "PUBLIC_BASE_URL" => "https://event.example",
      "ADMIN_FRONTEND_URL" => "https://event.example/admin",
      "GOOGLE_OAUTH_CALLBACK_URL" => "https://event.example/api/auth/google/callback",
      "GOOGLE_CLIENT_ID" => "test-client.apps.googleusercontent.com",
      "GOOGLE_CLIENT_SECRET" => "test-client-secret",
      "ADMIN_EMAIL_ALLOWLIST" => ""
    ) do
      host! "event.example"
      https!
      get "/api/auth/google/start"
      state = URI.decode_www_form(URI.parse(response.headers.fetch("Location")).query).to_h.fetch("state")
      stub_google_exchange(claims: { "email" => identity.email, "email_verified" => true, "sub" => identity.google_sub, "nonce" => state })

      get "/api/auth/google/callback", params: { code: "authorization-code", state: state }
      expect(response).to have_http_status(:found)
    end

    entry = AuditLog.find_by(event_type: "ADMIN_LOGIN_SUCCEEDED")
    expect(entry).to have_attributes(admin_identity_id: identity.id, actor_email: identity.email)
    expect(entry.detail).to eq("accessSource" => "MANAGEMENT_ACCESS")
  end

  it "does not record a login for applicant-only sessions" do
    with_env(
      "PUBLIC_BASE_URL" => "https://event.example",
      "ADMIN_FRONTEND_URL" => "https://event.example/admin",
      "GOOGLE_OAUTH_CALLBACK_URL" => "https://event.example/api/auth/google/callback",
      "GOOGLE_CLIENT_ID" => "test-client.apps.googleusercontent.com",
      "GOOGLE_CLIENT_SECRET" => "test-client-secret",
      "ADMIN_EMAIL_ALLOWLIST" => ""
    ) do
      host! "event.example"
      https!
      get "/api/auth/google/start"
      state = URI.decode_www_form(URI.parse(response.headers.fetch("Location")).query).to_h.fetch("state")
      stub_google_exchange(claims: { "email" => "applicant@example.com", "email_verified" => true, "sub" => "applicant-sub", "nonce" => state })

      get "/api/auth/google/callback", params: { code: "authorization-code", state: state }
      expect(response).to have_http_status(:found)
    end

    expect(AuditLog.where(event_type: "ADMIN_LOGIN_SUCCEEDED")).to be_empty
  end

  it "records ADMIN_LOGGED_OUT for a management session" do
    post "/api/admin/auth/logout"
    expect(response).to have_http_status(:no_content)

    entry = AuditLog.find_by(event_type: "ADMIN_LOGGED_OUT")
    expect(entry).to have_attributes(admin_identity_id: manager.identity.id, actor_email: manager.identity.email)
  end

  it "records ADMIN_ACCESS_EXCHANGED when an approved applicant session is upgraded" do
    identity = AdminIdentity.create!(email: "exchange@example.com", google_sub: "exchange-sub", admin_enabled: true)
    device = SecureRandom.urlsafe_base64(32, false)
    session_key = SecureRandom.urlsafe_base64(32, false)
    device_session = AdminDeviceSession.create!(
      admin_identity: identity,
      device_id_hash: Digest::SHA256.digest(device),
      session_key_hash: Digest::SHA256.digest(session_key),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: "APPLICANT",
      expires_at: 20.minutes.from_now,
      last_seen_at: Time.current
    )
    AdminAccessRequest.create!(
      email: identity.email,
      google_sub: identity.google_sub,
      status: "APPROVED",
      expires_at: device_session.expires_at,
      applicant_session: device_session,
      applicant_device_id_hash: Digest::SHA256.digest(device),
      applicant_session_key_hash: Digest::SHA256.digest(session_key)
    )

    clear_admin_cookies
    cookies[AdminAuth::DEVICE_COOKIE] = device
    cookies[AdminAuth::APPLICANT_SESSION_COOKIE] = session_key
    post "/api/admin/auth/exchange"
    expect(response).to have_http_status(:no_content)

    entry = AuditLog.find_by(event_type: "ADMIN_ACCESS_EXCHANGED")
    expect(entry).to have_attributes(admin_identity_id: identity.id, actor_email: identity.email)
  end

  it "records ACCESS_REQUEST_APPROVED and ACCESS_REQUEST_REJECTED" do
    allow_any_instance_of(AdminAuth).to receive(:decide_access_request!).and_return(
      AdminAccessRequest.new(id: 42, email: "applicant@example.com", status: "APPROVED", created_at: Time.current, expires_at: 1.hour.from_now)
    )

    post "/api/admin/access-requests/42/approve"
    expect(response).to have_http_status(:ok)
    post "/api/admin/access-requests/42/reject"
    expect(response).to have_http_status(:ok)

    expect(AuditLog.where(event_type: "ACCESS_REQUEST_APPROVED").pick(:actor_email)).to eq(manager.identity.email)
    expect(AuditLog.where(event_type: "ACCESS_REQUEST_REJECTED").pick(:target_id)).to eq("42")
  end

  it "records MANAGEMENT_ACCESS_REVOKED" do
    identity = AdminIdentity.create!(email: "revoke-target@example.com", google_sub: "revoke-target-sub", admin_enabled: true)
    allow_any_instance_of(AdminAuth).to receive(:deactivate_management_access!)

    delete "/api/admin/allowed-emails/#{identity.id}"
    expect(response).to have_http_status(:no_content)

    entry = AuditLog.find_by(event_type: "MANAGEMENT_ACCESS_REVOKED")
    expect(entry).to have_attributes(target_type: "ADMIN_IDENTITY", target_id: identity.id, actor_email: manager.identity.email)
    expect(entry.detail).to include("targetEmail" => identity.email)
  end

  it "records OPERATOR_ACCESS_GRANTED and OPERATOR_ACCESS_REVOKED" do
    operator_identity = Data.define(:id, :email, :google_sub).new(SecureRandom.uuid, "operator@example.com", "operator-sub")
    allow_any_instance_of(OperatorAuth).to receive(:set_management_access!).and_return(operator_identity)
    allow_any_instance_of(OperatorAuth).to receive(:management_identity_json).and_return({ email: "operator@example.com" })

    patch "/api/admin/operator-identities/#{operator_identity.id}", params: { managerEnabled: true }, as: :json
    expect(response).to have_http_status(:ok)

    patch "/api/admin/operator-identities/#{operator_identity.id}", params: { managerEnabled: false }, as: :json
    expect(response).to have_http_status(:ok)

    granted = AuditLog.find_by(event_type: "OPERATOR_ACCESS_GRANTED")
    expect(granted).to have_attributes(target_type: "OPERATOR_IDENTITY", target_id: operator_identity.id, actor_email: manager.identity.email)
    expect(granted.detail).to include("operatorEmail" => "operator@example.com", "managerEnabled" => true)
    expect(AuditLog.where(event_type: "OPERATOR_ACCESS_REVOKED").pick(:detail)).to include("managerEnabled" => false)
  end

  private

  def stub_google_exchange(claims:)
    token_response = Net::HTTPOK.new("1.1", "200", "OK").tap do |response|
      response.instance_variable_set(:@body, JSON.generate(id_token: "signed-id-token", access_token: "google-access-token"))
      response.instance_variable_set(:@read, true)
    end
    allow(Net::HTTP).to receive(:post_form).and_return(token_response)
    allow(Google::Auth::IDTokens).to receive(:verify_oidc).and_return(claims)
  end

  def question_payload(question_text: "監査対象の問題")
    {
      questionText: question_text,
      choiceA: "選択肢A",
      choiceB: "選択肢B",
      choiceC: "選択肢C",
      choiceD: "選択肢D",
      correctAnswer: "A"
    }
  end

  def authenticate_admin_as(session, cookie_name = AdminAuth::SESSION_COOKIE)
    clear_admin_cookies
    cookies[AdminAuth::DEVICE_COOKIE] = session.device
    cookies[cookie_name] = session.session_key
  end

  def clear_admin_cookies
    [ AdminAuth::DEVICE_COOKIE, AdminAuth::SESSION_COOKIE, AdminAuth::APPLICANT_SESSION_COOKIE ].each do |name|
      cookies.delete(name)
    end
  end

  def build_admin_session(source, admin_enabled: false)
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
