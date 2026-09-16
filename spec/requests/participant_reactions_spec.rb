require "rails_helper"

RSpec.describe "Participant waiting reactions", type: :request do
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

  it "records server-owned reaction data without returning participant data" do
    post "/api/participants", params: registration, headers: allowed_origin_headers, as: :json
    participant = Participant.sole
    participant_session = ParticipantSession.sole
    other_participant = create_participant("Other Player")
    other_session = create_participant_session(other_participant)
    client_timestamp = 1.week.ago.utc.iso8601

    expect {
      post "/api/participants/reactions", params: {
        reaction: "👏",
        participant_id: other_participant.id,
        participant_session_id: other_session.id,
        session: other_session.id,
        participantId: other_participant.id,
        participantSessionId: other_session.id,
        reacted_at: client_timestamp,
        timestamp: client_timestamp
      }, headers: allowed_origin_headers, as: :json
    }.to change(ParticipantReaction, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(response.body).to be_empty
    event = ParticipantReaction.sole
    expect(event).to have_attributes(participant:, participant_session:, reaction: "👏")
    expect(event.reacted_at).to be_within(1.second).of(Time.current)
    expect(event.reacted_at.iso8601).not_to eq(client_timestamp)
  end

  it "rate limits reactions within 500ms for the current session without creating another event" do
    post "/api/participants", params: registration, headers: allowed_origin_headers, as: :json
    participant_session = ParticipantSession.sole

    post "/api/participants/reactions", params: { reaction: "👏" }, headers: allowed_origin_headers, as: :json
    expect(response).to have_http_status(:created)

    expect {
      post "/api/participants/reactions", params: { reaction: "🎉" }, headers: allowed_origin_headers, as: :json
    }.not_to change(ParticipantReaction, :count)

    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body).to eq("error" => "Reaction rate limit exceeded")

    participant_session.update!(last_reaction_at: 0.501.seconds.ago)
    post "/api/participants/reactions", params: { reaction: "🎉" }, headers: allowed_origin_headers, as: :json

    expect(response).to have_http_status(:created)
    expect(ParticipantReaction.count).to eq(2)
  end

  it "rejects missing, malformed, and unknown reactions without recording an event" do
    post "/api/participants", params: registration, headers: allowed_origin_headers, as: :json

    post "/api/participants/reactions", params: {}, headers: allowed_origin_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "reaction is required")

    post "/api/participants/reactions", params: "{\"reaction\":", headers: allowed_origin_headers.merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "Malformed JSON")

    post "/api/participants/reactions", params: { reaction: "🔥" }, headers: allowed_origin_headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("Reaction is not included in the list")
    expect(ParticipantReaction.count).to eq(0)
  end

  it "requires the current participant session and same-origin request" do
    post "/api/participants/reactions", params: { reaction: "👏" }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "Participant session is required")

    post "/api/participants", params: registration, headers: allowed_origin_headers, as: :json
    post "/api/participants/reactions", params: { reaction: "👏" }, headers: { "Origin" => "https://untrusted.example" }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "Origin is not allowed")
    expect(ParticipantReaction.count).to eq(0)
  end

  private

  def create_participant(display_name)
    Participant.create!(
      display_name:,
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
  end

  def create_participant_session(participant)
    ParticipantSession.create!(
      participant:,
      token_hash: Digest::SHA256.digest(SecureRandom.hex),
      expires_at: 1.day.from_now
    )
  end
end
