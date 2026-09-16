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

  it "records every allowed reaction as a timestamped event without returning participant data" do
    post "/api/participants", params: registration, headers: allowed_origin_headers, as: :json
    participant = Participant.sole
    participant_session = ParticipantSession.sole

    expect {
      post "/api/participants/reactions", params: { reaction: "👏" }, headers: allowed_origin_headers, as: :json
      post "/api/participants/reactions", params: { reaction: "👏" }, headers: allowed_origin_headers, as: :json
    }.to change(ParticipantReaction, :count).by(2)

    expect(response).to have_http_status(:created)
    expect(response.body).to be_empty
    expect(ParticipantReaction.order(:created_at)).to all(
      have_attributes(participant:, participant_session:, reaction: "👏")
    )
    expect(ParticipantReaction.order(:created_at).first.reacted_at).to be_within(1.second).of(Time.current)
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
end
