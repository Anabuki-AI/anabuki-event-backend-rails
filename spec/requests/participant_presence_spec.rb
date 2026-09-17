require "rails_helper"

RSpec.describe "Participant waiting presence", type: :request do
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

  let(:allowed_origin_headers) { { "Origin" => ENV.fetch("PUBLIC_BASE_URL") } }

  it "records the current heartbeat and returns a non-cacheable aggregate without participant data" do
    post "/api/participants", params: registration, as: :json
    current_session = ParticipantSession.sole
    active_participant = create_participant

    create_participant_session(active_participant, heartbeat_at: 1.second.ago)
    create_participant_session(active_participant, heartbeat_at: 2.seconds.ago)
    create_participant_session(create_participant, heartbeat_at: 76.seconds.ago)
    create_participant_session(create_participant, heartbeat_at: 1.second.ago, revoked_at: Time.current)
    create_participant_session(create_participant, heartbeat_at: 1.second.ago, expires_at: 1.second.ago)

    post "/api/participants/presence", headers: allowed_origin_headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.headers.fetch("Cache-Control")).to eq("no-store")
    expect(response.parsed_body).to have_attributes(size: 4)
    expect(response.parsed_body).to include(
      "activeParticipantCount" => 2,
      "totalParticipantCount" => 5,
      "activeWindowSeconds" => 75
    )
    expect(response.parsed_body.fetch("observedAt")).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    expect(Time.iso8601(response.parsed_body.fetch("observedAt"))).to be_present
    expect(current_session.reload.waiting_heartbeat_at).to be_within(1.second).of(Time.current)
  end

  it "rejects presence after the participant session is deleted" do
    post "/api/participants", params: registration, headers: allowed_origin_headers, as: :json

    delete "/api/participants/session", headers: allowed_origin_headers
    expect(response).to have_http_status(:no_content)

    post "/api/participants/presence", headers: allowed_origin_headers, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "Participant session is required")
  end

  it "requires a valid participant session and rejects cross-origin heartbeats" do
    post "/api/participants/presence", as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "Participant session is required")

    post "/api/participants", params: registration, as: :json
    current_session = ParticipantSession.sole

    post "/api/participants/presence", headers: { "Origin" => "https://untrusted.example" }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "Origin is not allowed")
    expect(current_session.reload.waiting_heartbeat_at).to be_nil
  end

  private

  def create_participant
    Participant.create!(
      display_name: "Another Player",
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
  end

  def create_participant_session(participant, heartbeat_at:, expires_at: 1.day.from_now, revoked_at: nil)
    ParticipantSession.create!(
      participant:,
      token_hash: Digest::SHA256.digest(SecureRandom.hex),
      waiting_heartbeat_at: heartbeat_at,
      expires_at:,
      revoked_at:
    )
  end
end
