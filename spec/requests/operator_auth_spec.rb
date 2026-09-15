require "rails_helper"

RSpec.describe "Operator Google OAuth authentication", type: :request do
  let(:oauth_env) do
    {
      "PUBLIC_BASE_URL" => "https://event.example",
      "OPERATOR_FRONTEND_URL" => "https://event.example/operator",
      "GOOGLE_OAUTH_CALLBACK_URL" => "https://event.example/api/auth/google/callback",
      "GOOGLE_CLIENT_ID" => "test-client.apps.googleusercontent.com",
      "GOOGLE_CLIENT_SECRET" => "test-client-secret",
      "OPERATOR_EMAIL_ALLOWLIST" => " Manager@Example.COM "
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
    Operator::DeviceSession.delete_all
    Operator::OauthState.delete_all
    Operator::Identity.delete_all
  end

  def start_operator_oauth
    get "/api/auth/operator/google/start"

    expect(response).to have_http_status(:found)
    URI.decode_www_form(URI.parse(response.headers.fetch("Location")).query).to_h
  end

  def complete_operator_oauth(state:, code: "authorization-code")
    get "/api/auth/operator/google/callback", params: { code:, state: }
  end

  def google_claims(state:, email: "manager@example.com", sub: "operator-subject")
    {
      "email" => email,
      "email_verified" => true,
      "sub" => sub,
      "nonce" => state
    }
  end

  def oauth_token_response(id_token: "signed-id-token")
    Net::HTTPOK.new("1.1", "200", "OK").tap do |token_response|
      token_response.instance_variable_set(
        :@body,
        JSON.generate(id_token:, access_token: "google-access-token")
      )
      token_response.instance_variable_set(:@read, true)
    end
  end

  def expect_google_exchange(code:, claims:, id_token: "signed-id-token")
    expect(Net::HTTP).to receive(:post_form).with(
      URI("https://oauth2.googleapis.com/token"),
      code:,
      client_id: oauth_env.fetch("GOOGLE_CLIENT_ID"),
      client_secret: oauth_env.fetch("GOOGLE_CLIENT_SECRET"),
      redirect_uri: "https://event.example/api/auth/operator/google/callback",
      grant_type: "authorization_code"
    ).and_return(oauth_token_response(id_token:))
    expect(Google::Auth::IDTokens).to receive(:verify_oidc)
      .with(id_token, aud: oauth_env.fetch("GOOGLE_CLIENT_ID"))
      .and_return(claims)
  end

  def expect_no_google_exchange
    expect(Net::HTTP).not_to receive(:post_form)
    expect(Google::Auth::IDTokens).not_to receive(:verify_oidc)
  end

  it "refuses to start OAuth without creating state when unconfigured" do
    with_env("GOOGLE_CLIENT_SECRET" => "") do
      expect {
        get "/api/auth/operator/google/start"
      }.not_to change(Operator::OauthState, :count)

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq("error" => "Google OAuth is not configured")
      expect(cookies[OperatorAuth::DEVICE_COOKIE]).to be_nil
      expect(cookies[OperatorAuth::OAUTH_STATE_COOKIE]).to be_nil
    end
  end

  it "starts OAuth with a bound state, device cookie, and operator callback" do
    get "/api/auth/operator/google/start"

    expect(response).to have_http_status(:found)
    authorization_uri = URI.parse(response.headers.fetch("Location"))
    authorization_params = URI.decode_www_form(authorization_uri.query).to_h
    state = authorization_params.fetch("state")

    expect(authorization_uri).to have_attributes(
      scheme: "https",
      host: "accounts.google.com",
      path: "/o/oauth2/v2/auth"
    )
    expect(authorization_params).to include(
      "client_id" => oauth_env.fetch("GOOGLE_CLIENT_ID"),
      "redirect_uri" => "https://event.example/api/auth/operator/google/callback",
      "response_type" => "code",
      "scope" => "openid email",
      "nonce" => state,
      "prompt" => "select_account"
    )
    expect(cookies[OperatorAuth::OAUTH_STATE_COOKIE]).to eq(state)
    expect(cookies[OperatorAuth::DEVICE_COOKIE]).to match(/\A[A-Za-z0-9_-]{40,64}\z/)
    set_cookie = Array(response.headers.fetch("Set-Cookie")).join("\n").downcase
    expect(set_cookie).to include("httponly", "samesite=lax", "secure")

    persisted_state = Operator::OauthState.sole
    expect(persisted_state.state_hash).to eq(Digest::SHA256.digest(state))
    expect(persisted_state.expires_at).to be > Time.current
  end

  it "creates an allowlisted operator identity and a device-bound session in the operator database" do
    state = start_operator_oauth.fetch("state")
    expect_google_exchange(code: "operator-code", claims: google_claims(state:, email: "MANAGER@example.com"))

    complete_operator_oauth(state:, code: "operator-code")

    expect(response).to redirect_to(oauth_env.fetch("OPERATOR_FRONTEND_URL"))
    expect(Operator::OauthState.count).to eq(0)
    expect(cookies[OperatorAuth::OAUTH_STATE_COOKIE]).to be_blank

    identity = Operator::Identity.find_by!(google_sub: "operator-subject")
    expect(identity.email).to eq("manager@example.com")

    device_id = cookies[OperatorAuth::DEVICE_COOKIE]
    session_key = cookies[OperatorAuth::SESSION_COOKIE]
    record = Operator::DeviceSession.sole
    expect(device_id).to match(/\A[A-Za-z0-9_-]{40,64}\z/)
    expect(session_key).to match(/\A[A-Za-z0-9_-]{40,64}\z/)
    expect(record).to be_manager
    expect(record.operator_identity_id).to eq(identity.id)
    expect(record.device_id_hash).to eq(Digest::SHA256.digest(device_id))
    expect(record.session_key_hash).to eq(Digest::SHA256.digest(session_key))

    # The operator database stays isolated from the admin database.
    expect(AdminIdentity.count).to eq(0)
    expect(AdminDeviceSession.count).to eq(0)

    get "/api/operator/auth/session"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      "email" => "manager@example.com",
      "googleSub" => "operator-subject",
      "expiresAt" => record.expires_at.iso8601
    )
    expect(response.parsed_body).not_to have_key("deviceIdHash")
    expect(response.parsed_body).not_to have_key("sessionKeyHash")
  end

  it "reuses the same operator identity and rotates the session on a second login" do
    first_state = start_operator_oauth.fetch("state")
    expect_google_exchange(
      code: "first-code",
      claims: google_claims(state: first_state),
      id_token: "first-signed-id-token"
    )
    complete_operator_oauth(state: first_state, code: "first-code")
    original_identity = Operator::Identity.sole
    original_session_key = cookies[OperatorAuth::SESSION_COOKIE]

    second_state = start_operator_oauth.fetch("state")
    expect_google_exchange(
      code: "second-code",
      claims: google_claims(state: second_state),
      id_token: "second-signed-id-token"
    )

    expect {
      complete_operator_oauth(state: second_state, code: "second-code")
    }.not_to change(Operator::Identity, :count)

    expect(Operator::Identity.sole).to eq(original_identity)
    expect(cookies[OperatorAuth::SESSION_COOKIE]).to be_present
    expect(cookies[OperatorAuth::SESSION_COOKIE]).not_to eq(original_session_key)
    expect(Operator::DeviceSession.sole.session_key_hash).to eq(Digest::SHA256.digest(cookies[OperatorAuth::SESSION_COOKIE]))
  end

  it "rejects a Google account outside the operator allowlist with 403" do
    state = start_operator_oauth.fetch("state")
    expect_google_exchange(code: "outsider-code", claims: google_claims(state:, email: "outsider@example.com", sub: "outsider-subject"))

    expect {
      complete_operator_oauth(state:, code: "outsider-code")
    }.not_to change(Operator::Identity, :count)

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "Operator access is not allowed for this account")
    expect(Operator::DeviceSession.count).to eq(0)
    expect(cookies[OperatorAuth::SESSION_COOKIE]).to be_nil
  end

  it "rejects missing, tampered, mismatched, and expired states before contacting Google" do
    expect_no_google_exchange

    get "/api/auth/operator/google/callback", params: { state: "some-state" }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "OAuth callback is missing code or state")

    get "/api/auth/operator/google/callback", params: { code: "authorization-code" }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "OAuth callback is missing code or state")

    original_state = start_operator_oauth.fetch("state")
    complete_operator_oauth(state: "tampered-#{original_state}")
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "OAuth state validation failed")

    start_operator_oauth
    complete_operator_oauth(state: original_state)
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "OAuth state validation failed")

    state = start_operator_oauth.fetch("state")
    Operator::OauthState.find_by!(state_hash: Digest::SHA256.digest(state)).update!(expires_at: 1.second.ago)
    complete_operator_oauth(state:)
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "OAuth state validation failed")
  end

  it "rejects a replayed callback without another Google exchange" do
    state = start_operator_oauth.fetch("state")
    expect_google_exchange(code: "replay-code", claims: google_claims(state:))

    complete_operator_oauth(state:, code: "replay-code")
    expect(response).to redirect_to(oauth_env.fetch("OPERATOR_FRONTEND_URL"))

    # Restore the consumed cookie so this tests server-side state replay protection.
    cookies[OperatorAuth::OAUTH_STATE_COOKIE] = state
    expect {
      complete_operator_oauth(state:, code: "replay-code")
    }.not_to change(Operator::DeviceSession, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "OAuth state validation failed")
  end

  it "rejects an ID token with an invalid nonce without creating a session" do
    state = start_operator_oauth.fetch("state")
    expect_google_exchange(
      code: "invalid-nonce-code",
      claims: google_claims(state:).merge("nonce" => "different-nonce")
    )

    expect {
      complete_operator_oauth(state:, code: "invalid-nonce-code")
    }.not_to change(Operator::Identity, :count)

    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body).to eq("error" => "Google authentication failed")
    expect(cookies[OperatorAuth::SESSION_COOKIE]).to be_nil
  end

  it "rejects unknown or expired sessions" do
    get "/api/operator/auth/session"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "Authentication is required")

    cookies[OperatorAuth::DEVICE_COOKIE] = SecureRandom.urlsafe_base64(32, false)
    cookies[OperatorAuth::SESSION_COOKIE] = SecureRandom.urlsafe_base64(32, false)
    get "/api/operator/auth/session"

    expect(response).to have_http_status(:unauthorized)
  end

  it "logs out a manager session only for same-origin requests" do
    state = start_operator_oauth.fetch("state")
    expect_google_exchange(code: "logout-code", claims: google_claims(state:))
    complete_operator_oauth(state:, code: "logout-code")
    record = Operator::DeviceSession.sole

    post "/api/operator/auth/logout", headers: { "Origin" => "https://attacker.example" }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "Origin is not allowed")
    expect(record.reload.revoked_at).to be_nil

    post "/api/operator/auth/logout", headers: { "Origin" => oauth_env.fetch("PUBLIC_BASE_URL") }

    expect(response).to have_http_status(:no_content)
    expect(record.reload.revoked_at).to be_present
    expect(cookies[OperatorAuth::SESSION_COOKIE]).to be_blank

    get "/api/operator/auth/session"

    expect(response).to have_http_status(:unauthorized)
  end
end
