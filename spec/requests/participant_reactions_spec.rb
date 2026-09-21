require "rails_helper"

RSpec.describe "Participant waiting reactions", type: :request do
  around do |example|
    with_env("PUBLIC_BASE_URL" => "https://event.example") do
      host! "event.example"
      https!
      ReactionEventStore.clear!
      example.run
      ReactionEventStore.clear!
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

  it "records only an ephemeral server-owned event without changing participant records" do
    post "/api/participants", params: registration, headers: allowed_origin_headers, as: :json
    participant = Participant.sole
    participant_session = ParticipantSession.sole
    client_timestamp = 1.week.ago.utc.iso8601

    expect {
      post "/api/participants/reactions", params: {
        reaction: "👏",
        participant_id: SecureRandom.uuid,
        participant_session_id: SecureRandom.uuid,
        reacted_at: client_timestamp
      }, headers: allowed_origin_headers, as: :json
    }.not_to change { [ Participant.count, ParticipantSession.count ] }

    expect(response).to have_http_status(:created)
    expect(response.body).to be_empty
    event = ReactionEventStore.events_since(since: 1.minute.ago).sole
    expect(event).to have_attributes(reaction: "👏")
    expect(event.at).to be_within(1.second).of(Time.current)
    expect(event.at.iso8601).not_to eq(client_timestamp)
    expect(participant_session.attributes).not_to have_key("last_reaction_at")
    expect(ApplicationRecord.connection.data_source_exists?("participant_reactions")).to be(false)
    expect(participant).to be_persisted
  end

  it "rate limits reactions within 500ms for the current session without adding another event" do
    post "/api/participants", params: registration, headers: allowed_origin_headers, as: :json

    post "/api/participants/reactions", params: { reaction: "👏" }, headers: allowed_origin_headers, as: :json
    expect(response).to have_http_status(:created)

    expect {
      post "/api/participants/reactions", params: { reaction: "🎉" }, headers: allowed_origin_headers, as: :json
    }.not_to change { ReactionEventStore.events_since(since: 1.minute.ago).length }

    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body).to eq("error" => "Reaction rate limit exceeded")
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
    expect(response.parsed_body).to eq("error" => "Reaction is not included in the list")
    expect(ReactionEventStore.events_since(since: 1.minute.ago)).to eq([])
  end

  it "requires the current participant session and same-origin request" do
    post "/api/participants/reactions", params: { reaction: "👏" }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "Participant session is required")

    post "/api/participants", params: registration, headers: allowed_origin_headers, as: :json
    post "/api/participants/reactions", params: { reaction: "👏" }, headers: { "Origin" => "https://untrusted.example" }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "Origin is not allowed")
    expect(ReactionEventStore.events_since(since: 1.minute.ago)).to eq([])
  end
end
