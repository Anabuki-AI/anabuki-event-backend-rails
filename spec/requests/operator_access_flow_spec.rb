require "rails_helper"

RSpec.describe "Operator access request flow", type: :request do
  let(:oauth_env) do
    {
      "PUBLIC_BASE_URL" => "https://event.example",
      "OPERATOR_FRONTEND_URL" => "https://event.example/operator",
      "GOOGLE_OAUTH_CALLBACK_URL" => "https://event.example/api/auth/google/callback",
      "GOOGLE_CLIENT_ID" => "test-client.apps.googleusercontent.com",
      "GOOGLE_CLIENT_SECRET" => "test-client-secret"
    }
  end

  around do |example|
    with_env(oauth_env) do
      host! "event.example"
      https!
      example.run
    end
  end

  # Operator tables live in a separate database, which transactional fixtures
  # do not roll back; clean them before every example.
  before do
    Operator::AccessRequest.delete_all
    Operator::DeviceSession.delete_all
    Operator::OauthState.delete_all
    Operator::Identity.delete_all
  end

  def login_as_applicant(email: "applicant@example.com", sub: "applicant-subject")
    state = start_operator_oauth.fetch("state")
    expect_google_exchange(code: "applicant-code", claims: { "email" => email, "email_verified" => true, "sub" => sub, "nonce" => state })
    complete_operator_oauth(state:, code: "applicant-code")
    expect(response).to redirect_to(oauth_env.fetch("OPERATOR_FRONTEND_URL"))
  end

  def start_operator_oauth
    get "/api/auth/operator/google/start"
    expect(response).to have_http_status(:found)
    URI.decode_www_form(URI.parse(response.headers.fetch("Location")).query).to_h
  end

  def complete_operator_oauth(state:, code:)
    get "/api/auth/operator/google/callback", params: { code:, state: }
  end

  def oauth_token_response(id_token:)
    Net::HTTPOK.new("1.1", "200", "OK").tap do |token_response|
      token_response.instance_variable_set(:@body, JSON.generate(id_token:, access_token: "google-access-token"))
      token_response.instance_variable_set(:@read, true)
    end
  end

  def expect_google_exchange(code:, claims:)
    expect(Net::HTTP).to receive(:post_form).with(
      URI("https://oauth2.googleapis.com/token"),
      code:,
      client_id: oauth_env.fetch("GOOGLE_CLIENT_ID"),
      client_secret: oauth_env.fetch("GOOGLE_CLIENT_SECRET"),
      redirect_uri: "https://event.example/api/auth/operator/google/callback",
      grant_type: "authorization_code"
    ).and_return(oauth_token_response(id_token: "signed-id-token"))
    expect(Google::Auth::IDTokens).to receive(:verify_oidc)
      .with("signed-id-token", aud: oauth_env.fetch("GOOGLE_CLIENT_ID"))
      .and_return(claims)
  end

  def authenticate_admin_as(source: "MANAGEMENT_ACCESS")
    admin = build_admin_session(source)
    cookies[AdminAuth::DEVICE_COOKIE] = admin.device
    cookies[AdminAuth::SESSION_COOKIE] = admin.session_key
    admin.identity
  end

  def build_admin_session(source)
    identity = AdminIdentity.create!(
      email: "approver-#{SecureRandom.uuid}@example.com",
      google_sub: "approver-sub-#{SecureRandom.uuid}",
      admin_enabled: source != "APPLICANT"
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
    Data.define(:identity, :record, :device, :session_key).new(identity, record, device, session_key)
  end

  def build_operator_applicant(email: "applicant@example.com", sub: nil)
    identity = Operator::Identity.create!(email:, google_sub: sub || "sub-#{SecureRandom.uuid}")
    device = SecureRandom.urlsafe_base64(32, false)
    key = SecureRandom.urlsafe_base64(32, false)
    record = Operator::DeviceSession.create!(
      operator_identity: identity,
      device_id_hash: digest(device),
      session_key_hash: digest(key),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: "APPLICANT",
      expires_at: 20.minutes.from_now,
      last_seen_at: Time.current
    )
    Data.define(:identity, :record, :device, :key).new(identity, record, device, key)
  end

  def clear_admin_cookies
    [ AdminAuth::DEVICE_COOKIE, AdminAuth::SESSION_COOKIE, AdminAuth::APPLICANT_SESSION_COOKIE ].each do |name|
      cookies.delete(name)
    end
  end

  def digest(value)
    Digest::SHA256.digest(value)
  end

  it "walks an outsider from applicant through admin approval to a manager session" do
    login_as_applicant
    expect(Operator::AccessRequest.count).to eq(0)

    # The applicant files a request bound to its device session.
    post "/api/operator/access-request", headers: { "Origin" => oauth_env.fetch("PUBLIC_BASE_URL") }

    expect(response).to have_http_status(:created)
    request = Operator::AccessRequest.sole
    expect(request).to be_pending
    expect(request.email).to eq("applicant@example.com")
    expect(request.google_sub).to eq("applicant-subject")
    expect(request.applicant_session).to eq(Operator::DeviceSession.sole)
    expect(response.parsed_body).to eq(
      "id" => request.id,
      "email" => request.email,
      "status" => "PENDING",
      "createdAt" => request.created_at.iso8601,
      "expiresAt" => request.expires_at.iso8601,
      "cancelledAt" => nil,
      "cancellationReason" => nil,
      "decidedAt" => nil
    )

    # GET returns the same bound request instead of creating a new one.
    get "/api/operator/access-request"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("id")).to eq(request.id)

    # Exchange is refused while the request is only pending.
    post "/api/operator/auth/exchange", headers: { "Origin" => oauth_env.fetch("PUBLIC_BASE_URL") }
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "The approved applicant session cannot be exchanged")

    # A second create returns the existing pending request.
    post "/api/operator/access-request", headers: { "Origin" => oauth_env.fetch("PUBLIC_BASE_URL") }
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("id")).to eq(request.id)
    expect(Operator::AccessRequest.count).to eq(1)

    # An admin with ACCESS_REQUEST_APPROVE sees and approves the request.
    approver = authenticate_admin_as
    get "/api/admin/operator-access-requests"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.map { |entry| entry.fetch("id") }).to contain_exactly(request.id)

    expect {
      post "/api/admin/operator-access-requests/#{request.id}/approve", headers: { "Origin" => oauth_env.fetch("PUBLIC_BASE_URL") }
    }.to change { request.reload.pending? }.from(true).to(false)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("status")).to eq("APPROVED")
    expect(request).to be_approved
    expect(request.approved_by_identity_id).to eq(approver.id)
    expect(request.applicant_session.operator_identity.reload).to be_manager_enabled

    # Exchange promotes the device session and rotates the cookie.
    expect {
      post "/api/operator/auth/exchange", headers: { "Origin" => oauth_env.fetch("PUBLIC_BASE_URL") }
    }.not_to change(Operator::DeviceSession, :count)

    expect(response).to have_http_status(:no_content)
    record = Operator::DeviceSession.sole.reload
    expect(record).to be_manager
    expect(record.expires_at).to be > 7.hours.from_now
    expect(cookies[OperatorAuth::SESSION_COOKIE]).to be_present
    expect(cookies[OperatorAuth::APPLICANT_SESSION_COOKIE]).to be_blank

    get "/api/operator/auth/session"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("accessSource" => "MANAGER")
  end

  it "keeps the applicant an applicant after an admin rejection" do
    login_as_applicant
    post "/api/operator/access-request", headers: { "Origin" => oauth_env.fetch("PUBLIC_BASE_URL") }
    request = Operator::AccessRequest.sole

    authenticate_admin_as
    post "/api/admin/operator-access-requests/#{request.id}/reject", headers: { "Origin" => oauth_env.fetch("PUBLIC_BASE_URL") }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("status")).to eq("REJECTED")
    expect(request.reload).to be_rejected
    expect(request.applicant_session.operator_identity.reload).not_to be_manager_enabled

    post "/api/operator/auth/exchange", headers: { "Origin" => oauth_env.fetch("PUBLIC_BASE_URL") }

    expect(response).to have_http_status(:forbidden)
    expect(Operator::DeviceSession.sole.reload).to be_applicant
  end

  it "refuses operator-request administration without an admin management session" do
    applicant = build_operator_applicant
    request = Operator::AccessRequest.create!(
      email: applicant.identity.email,
      google_sub: applicant.identity.google_sub,
      status: "PENDING",
      expires_at: applicant.record.expires_at,
      applicant_session: applicant.record,
      applicant_device_id_hash: digest(applicant.device),
      applicant_session_key_hash: digest(applicant.key)
    )

    get "/api/admin/operator-access-requests"
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "Authentication is required")

    post "/api/admin/operator-access-requests/#{request.id}/approve"
    expect(response).to have_http_status(:unauthorized)
    expect(request.reload).to be_pending

    # An admin applicant session may not administer either.
    admin_applicant = build_admin_session("APPLICANT")
    clear_admin_cookies
    cookies[AdminAuth::DEVICE_COOKIE] = admin_applicant.device
    cookies[AdminAuth::APPLICANT_SESSION_COOKIE] = admin_applicant.session_key
    get "/api/admin/operator-access-requests"

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "Management page access is required")
    expect(request.reload).to be_pending
  end

  it "rejects cross-origin approvals from an authorized admin session" do
    admin = AdminIdentity.create!(email: "approver@example.com", google_sub: "approver-sub", admin_enabled: true)
    device = SecureRandom.urlsafe_base64(32, false)
    session_key = SecureRandom.urlsafe_base64(32, false)
    AdminDeviceSession.create!(
      admin_identity: admin,
      device_id_hash: digest(device),
      session_key_hash: digest(session_key),
      email: admin.email,
      google_sub: admin.google_sub,
      access_source: "MANAGEMENT_ACCESS",
      expires_at: 1.hour.from_now,
      last_seen_at: Time.current
    )
    cookies[AdminAuth::DEVICE_COOKIE] = device
    cookies[AdminAuth::SESSION_COOKIE] = session_key

    post "/api/admin/operator-access-requests/#{SecureRandom.uuid}/approve", headers: { "Origin" => "https://attacker.example" }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "Origin is not allowed")
  end

  it "cancels the pending request when the applicant session is gone" do
    login_as_applicant
    post "/api/operator/access-request", headers: { "Origin" => oauth_env.fetch("PUBLIC_BASE_URL") }
    request = Operator::AccessRequest.sole

    Operator::DeviceSession.sole.update!(revoked_at: Time.current)
    authenticate_admin_as
    get "/api/admin/operator-access-requests"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq([])
    expect(request.reload).to be_cancelled
    expect(request.cancellation_reason).to eq("APPLICANT_SESSION_REVOKED")
  end
end
