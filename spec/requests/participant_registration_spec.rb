require "rails_helper"

RSpec.describe "Participant registration", type: :request do
  around do |example|
    with_env("PUBLIC_BASE_URL" => "https://event.example") do
      host! "event.example"
      https!
      example.run
    end
  end

  let(:registration) do
    {
      displayName: "Quiz Player",
      gender: "no_answer",
      ageGroup: "20s",
      studentType: "not_student",
      school: "",
      department: "",
      agreedTerms: true
    }
  end

  it "creates a UUID participant, stores only the session token hash, and issues a secure cookie" do
    expect {
      post "/api/participants", params: registration, as: :json
    }.to change(Participant, :count).by(1).and change(ParticipantSession, :count).by(1)

    participant = Participant.sole
    session = ParticipantSession.sole
    session_cookie = cookies[ParticipantAuth::SESSION_COOKIE]

    expect(response).to have_http_status(:created)
    expect(participant.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    expect(response.parsed_body).to eq(
      "id" => participant.id,
      "displayName" => "Quiz Player",
      "gender" => "no_answer",
      "ageGroup" => "20s",
      "studentType" => "not_student",
      "school" => "",
      "department" => "",
      "agreedTerms" => true,
      "sessionExpiresAt" => session.expires_at.iso8601
    )
    expect(session_cookie).to match(/\A[A-Za-z0-9_-]{40,64}\z/)
    expect(session.token_hash).to eq(Digest::SHA256.digest(session_cookie))
    expect(session.token_hash).not_to eq(session_cookie)
    expect(participant.attributes).not_to include("email", "password", "password_digest", "user_name")
    expect(response.body).not_to include(session.token_hash.unpack1("H*"))
    set_cookie = Array(response.headers.fetch("Set-Cookie")).join("\n").downcase
    expect(set_cookie).to include("httponly", "samesite=lax", "secure")
  end

  it "allows duplicate display names because they are not authentication identifiers" do
    2.times do
      post "/api/participants", params: registration, as: :json
      expect(response).to have_http_status(:created)
    end

    expect(Participant.where(display_name: registration[:displayName]).count).to eq(2)
  end

  it "returns the participant resolved from the cookie session" do
    post "/api/participants", params: registration, as: :json
    expected = response.parsed_body

    get "/api/participants/me"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(expected)
  end

  it "rejects a missing, expired, or revoked participant session" do
    get "/api/participants/me"
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "Participant session is required")

    post "/api/participants", params: registration, as: :json
    ParticipantSession.sole.update!(expires_at: 1.second.ago)
    get "/api/participants/me"
    expect(response).to have_http_status(:unauthorized)

    ParticipantSession.sole.update!(expires_at: 1.day.from_now, revoked_at: Time.current)
    get "/api/participants/me"
    expect(response).to have_http_status(:unauthorized)
  end

  it "revokes the current session and clears its cookie" do
    post "/api/participants", params: registration, as: :json
    raw_token = cookies[ParticipantAuth::SESSION_COOKIE]

    delete "/api/participants/session"

    expect(response).to have_http_status(:no_content)
    expect(ParticipantSession.sole.revoked_at).to be_present
    expect(cookies[ParticipantAuth::SESSION_COOKIE]).to be_nil
    expect(ParticipantSession.sole.token_hash).to eq(Digest::SHA256.digest(raw_token))
  end

  it "does not accept profile data without terms consent" do
    post "/api/participants", params: registration.merge(agreedTerms: false), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("Agreed terms")
  end

  it "rejects cross-origin registration and session deletion" do
    headers = { "Origin" => "https://untrusted.example" }

    post "/api/participants", params: registration, headers:, as: :json
    expect(response).to have_http_status(:forbidden)

    delete "/api/participants/session", headers:
    expect(response).to have_http_status(:forbidden)
  end
end
