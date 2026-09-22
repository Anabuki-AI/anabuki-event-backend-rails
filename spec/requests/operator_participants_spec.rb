require "rails_helper"

RSpec.describe "Operator participants", type: :request do
  around do |example|
    with_env(
      "PUBLIC_BASE_URL" => "https://event.example",
      "ADMIN_FRONTEND_URL" => "http://localhost:3000/admin",
      "OPERATOR_FRONTEND_URL" => "https://event.example/operator"
    ) do
      host! "event.example"
      https!
      example.run
    end
  end

  before do
    Operator::DeviceSession.delete_all
    Operator::Identity.delete_all
  end

  let(:operator_headers) do
    { "Origin" => "https://event.example" }
  end

  describe "GET /api/operator/participants" do
    it "returns every participant with their profile and answer count" do
      authenticate_operator(manager_enabled: true)
      participant = create_participant(display_name: "Quiz Player")
      other = create_participant(display_name: "Spectator")
      question = create_question(position: 1)
      ParticipantAnswer.create!(participant:, question:, choice: "B", confidence_level: "normal", awarded_points: 100)

      get "/api/operator/participants", headers: operator_headers, as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.size).to eq(2)

      entry = body.find { |item| item["id"] == participant.id }
      expect(entry).to include(
        "displayName" => "Quiz Player",
        "gender" => "no_answer",
        "ageGroup" => "20s",
        "studentType" => "not_student",
        "answeredCount" => 1,
        "registeredAt" => participant.created_at.iso8601
      )
      expect(body.find { |item| item["id"] == other.id }.fetch("answeredCount")).to eq(0)
    end

    it "requires an event-operator session" do
      get "/api/operator/participants", headers: operator_headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE /api/operator/participants/:id" do
    it "deletes the participant with their sessions and answers, and records an audit log" do
      authenticate_operator(manager_enabled: true)
      participant = create_participant(display_name: "NG Player")
      create_participant(display_name: "Keep Player")
      question = create_question(position: 1)
      ParticipantAnswer.create!(participant:, question:, choice: "A", confidence_level: "normal", awarded_points: 100)
      ParticipantSession.create!(participant:, token_hash: SecureRandom.random_bytes(32), expires_at: 1.hour.from_now)

      expect {
        delete "/api/operator/participants/#{participant.id}", headers: operator_headers, as: :json
      }.to change(Participant, :count).by(-1)
        .and change(ParticipantAnswer, :count).by(-1)
        .and change(ParticipantSession, :count).by(-1)
        .and change(AuditLog, :count).by(1)

      expect(response).to have_http_status(:no_content)
      log = AuditLog.sole
      expect(log).to have_attributes(event_type: "PARTICIPANT_DELETED", target_type: "PARTICIPANT", target_id: participant.id)
      expect(log.detail).to eq("displayName" => "NG Player")
    end

    it "returns 404 for an unknown participant" do
      authenticate_operator(manager_enabled: true)
      delete "/api/operator/participants/#{SecureRandom.uuid}", headers: operator_headers, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  def create_participant(display_name: "Quiz Player")
    Participant.create!(
      display_name:,
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
  end

  def create_question(position:)
    Question.create!(
      question_text: "問題#{position}",
      choice_a: "A",
      choice_b: "B",
      choice_c: "C",
      choice_d: "D",
      correct_answer: "A",
      position:
    )
  end

  def authenticate_operator(manager_enabled:)
    identity = Operator::Identity.create!(email: "operator-#{SecureRandom.uuid}@example.com", google_sub: "operator-#{SecureRandom.uuid}", manager_enabled:)
    device = SecureRandom.urlsafe_base64(32, false)
    session_key = SecureRandom.urlsafe_base64(32, false)
    Operator::DeviceSession.create!(
      operator_identity: identity,
      device_id_hash: Digest::SHA256.digest(device),
      session_key_hash: Digest::SHA256.digest(session_key),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: manager_enabled ? "MANAGER" : "APPLICANT",
      expires_at: 1.hour.from_now,
      last_seen_at: Time.current
    )
    cookies[OperatorAuth::DEVICE_COOKIE] = device
    cookies[manager_enabled ? OperatorAuth::SESSION_COOKIE : OperatorAuth::APPLICANT_SESSION_COOKIE] = session_key
  end
end
