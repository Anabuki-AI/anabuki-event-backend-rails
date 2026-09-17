require "rails_helper"

RSpec.describe "Google OAuth authentication", type: :request do
  let(:oauth_env) do
    {
      "PUBLIC_BASE_URL" => "https://event.example",
      "ADMIN_FRONTEND_URL" => "https://event.example/admin",
      "GOOGLE_OAUTH_CALLBACK_URL" => "https://event.example/api/auth/google/callback",
      "GOOGLE_CLIENT_ID" => "test-client.apps.googleusercontent.com",
      "GOOGLE_CLIENT_SECRET" => "test-client-secret",
      "ADMIN_EMAIL_ALLOWLIST" => " Environment@Example.COM "
    }
  end

  around do |example|
    with_env(oauth_env) do
      host! "event.example"
      https!
      example.run
    end
  end

  def start_google_oauth
    get "/api/auth/google/start"

    expect(response).to have_http_status(:found)
    URI.decode_www_form(URI.parse(response.headers.fetch("Location")).query).to_h
  end

  def complete_google_oauth(state:, code: "authorization-code")
    get "/api/auth/google/callback", params: { code:, state: }
  end

  def google_claims(state:, email: "Applicant@Example.COM", sub: "applicant-subject")
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
      redirect_uri: oauth_env.fetch("GOOGLE_OAUTH_CALLBACK_URL"),
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

  def expect_state_validation_failure
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "OAuth state validation failed")
    expect(AdminIdentity.count).to eq(0)
    expect(AdminDeviceSession.count).to eq(0)
  end

  def expect_google_authentication_failure
    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body).to eq("error" => "Google authentication failed")
    expect(AdminIdentity.count).to eq(0)
    expect(AdminDeviceSession.count).to eq(0)
    expect(cookies[AdminAuth::APPLICANT_SESSION_COOKIE]).to be_nil
    expect(cookies[AdminAuth::SESSION_COOKIE]).to be_nil
  end

  it "reports configured Google OAuth" do
    get "/api/auth/google/status"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("configured" => true)
  end

  it "reports unconfigured OAuth and refuses to start without creating state" do
    with_env("GOOGLE_CLIENT_SECRET" => "") do
      get "/api/auth/google/status"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("configured" => false)

      expect {
        get "/api/auth/google/start"
      }.not_to change(AdminOauthState, :count)

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq("error" => "Google OAuth is not configured")
      expect(cookies[AdminAuth::DEVICE_COOKIE]).to be_nil
      expect(cookies[AdminAuth::OAUTH_STATE_COOKIE]).to be_nil
    end
  end

  it "starts OAuth with a bound state and device cookie" do
    get "/api/auth/google/start"

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
      "redirect_uri" => oauth_env.fetch("GOOGLE_OAUTH_CALLBACK_URL"),
      "response_type" => "code",
      "scope" => "openid email",
      "nonce" => state,
      "prompt" => "select_account"
    )
    expect(cookies[AdminAuth::OAUTH_STATE_COOKIE]).to eq(state)
    expect(cookies[AdminAuth::DEVICE_COOKIE]).to match(/\A[A-Za-z0-9_-]{40,64}\z/)
    set_cookie = Array(response.headers.fetch("Set-Cookie")).join("\n").downcase
    expect(set_cookie).to include("httponly", "samesite=lax", "secure")

    persisted_state = AdminOauthState.sole
    expect(persisted_state.state_hash).to eq(Digest::SHA256.digest(state))
    expect(persisted_state.state_hash).not_to eq(state)
    expect(persisted_state.expires_at).to be > Time.current
  end

  it "creates a normalized applicant identity and a device-bound session" do
    state = start_google_oauth.fetch("state")
    expect_google_exchange(code: "applicant-code", claims: google_claims(state:))

    complete_google_oauth(state:, code: "applicant-code")

    expect(response).to redirect_to(oauth_env.fetch("ADMIN_FRONTEND_URL"))
    expect(AdminOauthState.count).to eq(0)
    expect(cookies[AdminAuth::OAUTH_STATE_COOKIE]).to be_blank

    identity = AdminIdentity.find_by!(google_sub: "applicant-subject")
    expect(identity.email).to eq("applicant@example.com")
    expect(identity.admin_enabled?).to be(false)
    expect(identity.attributes).not_to include("password", "password_digest")

    device_id = cookies[AdminAuth::DEVICE_COOKIE]
    applicant_session_key = cookies[AdminAuth::APPLICANT_SESSION_COOKIE]
    session = AdminDeviceSession.sole
    expect(device_id).to match(/\A[A-Za-z0-9_-]{40,64}\z/)
    expect(applicant_session_key).to match(/\A[A-Za-z0-9_-]{40,64}\z/)
    expect(session).to be_applicant
    expect(session.expires_at).to be_within(1.second).of(20.minutes.from_now)
    expect(session.device_id_hash).to eq(Digest::SHA256.digest(device_id))
    expect(session.session_key_hash).to eq(Digest::SHA256.digest(applicant_session_key))
    expect(session.device_id_hash).not_to eq(device_id)
    expect(session.session_key_hash).not_to eq(applicant_session_key)
    expect(response.body).not_to include("google-access-token")
    expect(response.body).not_to include(session.device_id_hash.unpack1("H*"))
    expect(response.body).not_to include(session.session_key_hash.unpack1("H*"))

    get "/api/admin/auth/session"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "email" => "applicant@example.com",
      "googleSub" => "applicant-subject",
      "accessSource" => "APPLICANT",
      "permissions" => [],
      "expiresAt" => session.expires_at.iso8601
    )
    expect(response.parsed_body).not_to have_key("accessToken")
    expect(response.parsed_body).not_to have_key("deviceIdHash")
    expect(response.parsed_body).not_to have_key("sessionKeyHash")
    expect(response.body).not_to include(session.device_id_hash.unpack1("H*"))
    expect(response.body).not_to include(session.session_key_hash.unpack1("H*"))
  end

  it "allows a Google applicant to request management access with uppercase API status" do
    state = start_google_oauth.fetch("state")
    expect_google_exchange(code: "authorization-code", claims: google_claims(state:))
    complete_google_oauth(state:)

    post "/api/admin/access-request", headers: { "Origin" => oauth_env.fetch("PUBLIC_BASE_URL") }

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("email" => "applicant@example.com", "status" => "PENDING")
    request_id = response.parsed_body.fetch("id")

    get "/api/admin/access-request"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => request_id, "status" => "PENDING")
  end

  it "reuses the same identity on a second Google login" do
    first_state = start_google_oauth.fetch("state")
    expect_google_exchange(
      code: "first-code",
      claims: google_claims(state: first_state),
      id_token: "first-signed-id-token"
    )
    complete_google_oauth(state: first_state, code: "first-code")
    original_identity = AdminIdentity.sole

    second_state = start_google_oauth.fetch("state")
    expect_google_exchange(
      code: "second-code",
      claims: google_claims(state: second_state),
      id_token: "second-signed-id-token"
    )

    expect {
      complete_google_oauth(state: second_state, code: "second-code")
    }.not_to change(AdminIdentity, :count)

    expect(response).to redirect_to(oauth_env.fetch("ADMIN_FRONTEND_URL"))
    expect(AdminIdentity.sole).to eq(original_identity)
  end

  it "gives an approved identity management access" do
    AdminIdentity.create!(
      email: "manager@example.com",
      google_sub: "manager-subject",
      admin_enabled: true
    )
    state = start_google_oauth.fetch("state")
    expect_google_exchange(
      code: "manager-code",
      claims: google_claims(state:, email: "manager@example.com", sub: "manager-subject")
    )

    complete_google_oauth(state:, code: "manager-code")
    session = AdminDeviceSession.sole
    get "/api/admin/auth/session"

    expect(response).to have_http_status(:ok)
    expect(session.expires_at).to be_within(1.second).of(3.weeks.from_now)
    expect(response.parsed_body).to include(
      "accessSource" => "MANAGEMENT_ACCESS",
      "permissions" => %w[MANAGEMENT_PAGE_VIEW ACCESS_REQUEST_APPROVE MANAGEMENT_ACCESS_REVOKE]
    )
    expect(cookies[AdminAuth::SESSION_COOKIE]).to be_present
    expect(cookies[AdminAuth::APPLICANT_SESSION_COOKIE]).to be_nil
  end

  it "gives an allowlisted identity environment access" do
    state = start_google_oauth.fetch("state")
    expect_google_exchange(
      code: "environment-code",
      claims: google_claims(state:, email: "ENVIRONMENT@example.com", sub: "environment-subject")
    )

    complete_google_oauth(state:, code: "environment-code")
    get "/api/admin/auth/session"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "email" => "environment@example.com",
      "accessSource" => "ENVIRONMENT_ACCESS",
      "permissions" => %w[MANAGEMENT_PAGE_VIEW ACCESS_REQUEST_APPROVE MANAGEMENT_ACCESS_REVOKE]
    )
    expect(cookies[AdminAuth::SESSION_COOKIE]).to be_present
    expect(cookies[AdminAuth::APPLICANT_SESSION_COOKIE]).to be_nil
  end

  it "rejects a callback with missing state before contacting Google" do
    expect_no_google_exchange

    get "/api/auth/google/callback", params: { code: "authorization-code" }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "OAuth callback is missing code or state")
    expect(AdminIdentity.count).to eq(0)
    expect(AdminDeviceSession.count).to eq(0)
  end

  it "rejects a callback missing its state cookie before contacting Google" do
    state = start_google_oauth.fetch("state")
    cookies.delete(AdminAuth::OAUTH_STATE_COOKIE)
    expect_no_google_exchange

    complete_google_oauth(state:)

    expect_state_validation_failure
  end

  it "rejects tampered state and state-cookie mismatches before contacting Google" do
    original_state = start_google_oauth.fetch("state")
    expect_no_google_exchange

    complete_google_oauth(state: "tampered-#{original_state}")
    expect_state_validation_failure

    start_google_oauth
    complete_google_oauth(state: original_state)
    expect_state_validation_failure
  end

  it "rejects an expired state before contacting Google" do
    state = start_google_oauth.fetch("state")
    AdminOauthState.find_by!(state_hash: Digest::SHA256.digest(state)).update!(expires_at: 1.second.ago)
    expect_no_google_exchange

    complete_google_oauth(state:)

    expect_state_validation_failure
  end

  it "rejects a replayed callback without another Google exchange" do
    state = start_google_oauth.fetch("state")
    expect_google_exchange(code: "replay-code", claims: google_claims(state:))

    complete_google_oauth(state:, code: "replay-code")
    expect(response).to redirect_to(oauth_env.fetch("ADMIN_FRONTEND_URL"))

    # Restore the consumed cookie so this tests server-side state replay protection.
    cookies[AdminAuth::OAUTH_STATE_COOKIE] = state
    expect {
      complete_google_oauth(state:, code: "replay-code")
    }.not_to change(AdminDeviceSession, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "OAuth state validation failed")
    expect(AdminIdentity.count).to eq(1)
  end

  it "rejects an ID token with an invalid nonce without creating a session" do
    state = start_google_oauth.fetch("state")
    expect_google_exchange(
      code: "invalid-nonce-code",
      claims: google_claims(state:).merge("nonce" => "different-nonce")
    )

    expect {
      complete_google_oauth(state:, code: "invalid-nonce-code")
    }.not_to change(AdminIdentity, :count)

    expect_google_authentication_failure
  end

  it "rejects an ID token with an unverified email without creating a session" do
    state = start_google_oauth.fetch("state")
    expect_google_exchange(
      code: "unverified-email-code",
      claims: google_claims(state:).merge("email_verified" => false)
    )

    expect {
      complete_google_oauth(state:, code: "unverified-email-code")
    }.not_to change(AdminIdentity, :count)

    expect_google_authentication_failure
  end

  it "rejects a Google ID token verification error without creating a session" do
    state = start_google_oauth.fetch("state")
    expect(Net::HTTP).to receive(:post_form).with(
      URI("https://oauth2.googleapis.com/token"),
      code: "verification-error-code",
      client_id: oauth_env.fetch("GOOGLE_CLIENT_ID"),
      client_secret: oauth_env.fetch("GOOGLE_CLIENT_SECRET"),
      redirect_uri: oauth_env.fetch("GOOGLE_OAUTH_CALLBACK_URL"),
      grant_type: "authorization_code"
    ).and_return(oauth_token_response)
    expect(Google::Auth::IDTokens).to receive(:verify_oidc)
      .with("signed-id-token", aud: oauth_env.fetch("GOOGLE_CLIENT_ID"))
      .and_raise(Google::Auth::IDTokens::VerificationError, "invalid ID token")

    expect {
      complete_google_oauth(state:, code: "verification-error-code")
    }.not_to change(AdminIdentity, :count)

    expect_google_authentication_failure
  end
end
