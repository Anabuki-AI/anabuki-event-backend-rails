require "rails_helper"

RSpec.describe "Operator quiz control", type: :request do
  around do |example|
    host! "localhost"
    example.run
  end

  before do
    Operator::DeviceSession.delete_all
    Operator::Identity.delete_all
  end

  let(:operator_headers) do
    { "Origin" => "https://event.example" }
  end

  describe "authorization" do
    it "requires an event operator session" do
      get "/api/operator/quiz/state"
      expect(response).to have_http_status(:unauthorized)

      authenticate_operator(manager_enabled: false)
      get "/api/operator/quiz/state"
      expect(response).to have_http_status(:unauthorized)
    end

    it "allows an operator manager session and an admin management session" do
      authenticate_operator(manager_enabled: true)
      get "/api/operator/quiz/state"
      expect(response).to have_http_status(:ok)

      Operator::DeviceSession.delete_all
      authenticate_admin
      get "/api/operator/quiz/state"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/operator/quiz/state" do
    it "returns the waiting state without a current question" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)

      get "/api/operator/quiz/state"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "status" => "waiting",
        "phase" => nil,
        "current" => nil,
        "question_count" => 1,
        "total_participants" => 0
      )
    end

    it "returns the current question with operator-only fields while in progress" do
      authenticate_operator(manager_enabled: true)
      question = create_question(position: 1, correct_answer: "B")
      create_participant
      QuizSession.current.start!

      get "/api/operator/quiz/state"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.slice("status", "phase", "question_count", "total_participants")).to eq(
        "status" => "in_progress",
        "phase" => "answering",
        "question_count" => 1,
        "total_participants" => 1
      )
      expect(body["current"]).to eq(
        "question_id" => question.id,
        "position" => 1,
        "question_text" => "Question 1",
        "choices" => { "A" => "choice A", "B" => "choice B", "C" => "choice C", "D" => "choice D" },
        "image_url" => nil,
        "correct_answer" => "B",
        "answered_count" => 0,
        "answered_rate" => 0.0
      )
    end
  end

  describe "POST /api/operator/quiz/start" do
    it "moves waiting to in_progress with the first question in answering phase" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 2)
      first = create_question(position: 1)

      post "/api/operator/quiz/start", headers: operator_headers, as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["status"]).to eq("in_progress")
      expect(body["phase"]).to eq("answering")
      expect(body["current"]["question_id"]).to eq(first.id)
    end

    it "rejects a double start with 422" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      QuizSession.current.start!

      post "/api/operator/quiz/start", headers: operator_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to be_present
    end

    it "rejects start when no questions are registered" do
      authenticate_operator(manager_enabled: true)

      post "/api/operator/quiz/start", headers: operator_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/operator/quiz/publish" do
    it "publishes the requested position and resets the phase to answering" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      second = create_question(position: 2)
      QuizSession.current.start!
      QuizSession.current.close!

      post "/api/operator/quiz/publish", params: { position: 2 }, headers: operator_headers, as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["phase"]).to eq("answering")
      expect(body["current"]["question_id"]).to eq(second.id)
    end

    it "rejects an unknown position with 422" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      QuizSession.current.start!

      post "/api/operator/quiz/publish", params: { position: 99 }, headers: operator_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects publish while waiting with 422" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)

      post "/api/operator/quiz/publish", params: { position: 1 }, headers: operator_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a missing position with 400" do
      authenticate_operator(manager_enabled: true)

      post "/api/operator/quiz/publish", params: {}, headers: operator_headers, as: :json

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "POST /api/operator/quiz/close and reveal" do
    it "closes answering and then reveals the answer" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      QuizSession.current.start!

      post "/api/operator/quiz/close", headers: operator_headers, as: :json
      expect(response.parsed_body["phase"]).to eq("closed")

      post "/api/operator/quiz/reveal", headers: operator_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["phase"]).to eq("revealed")
    end

    it "rejects double close and double reveal with 422" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      QuizSession.current.start!

      post "/api/operator/quiz/close", headers: operator_headers, as: :json
      post "/api/operator/quiz/close", headers: operator_headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      post "/api/operator/quiz/reveal", headers: operator_headers, as: :json
      post "/api/operator/quiz/reveal", headers: operator_headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects close while waiting with 422" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)

      post "/api/operator/quiz/close", headers: operator_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/operator/quiz/finish" do
    it "finishes from in_progress and clears the current question" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      QuizSession.current.start!

      post "/api/operator/quiz/finish", headers: operator_headers, as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["status"]).to eq("finished")
      expect(body["phase"]).to be_nil
      expect(body["current"]).to be_nil
    end

    it "rejects a double finish with 422" do
      authenticate_operator(manager_enabled: true)
      QuizSession.current.finish!

      post "/api/operator/quiz/finish", headers: operator_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects any transition after finishing" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      QuizSession.current.finish!

      post "/api/operator/quiz/start", headers: operator_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "single-row guarantee" do
    it "materializes exactly one session row regardless of access order" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)

      get "/api/operator/quiz/state"
      QuizSession.current.start!

      expect(QuizSession.count).to eq(1)
    end
  end

  private

  def create_question(position:, correct_answer: "A")
    Question.create!(
      position:,
      question_text: "Question #{position}",
      choice_a: "choice A",
      choice_b: "choice B",
      choice_c: "choice C",
      choice_d: "choice D",
      correct_answer:
    )
  end

  def create_participant
    Participant.create!(
      display_name: "Player",
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
  end

  def authenticate_admin
    identity = AdminIdentity.create!(email: "admin-#{SecureRandom.uuid}@example.com", google_sub: "admin-#{SecureRandom.uuid}", admin_enabled: true)
    device = SecureRandom.urlsafe_base64(32, false)
    session_key = SecureRandom.urlsafe_base64(32, false)
    AdminDeviceSession.create!(
      admin_identity: identity,
      device_id_hash: Digest::SHA256.digest(device),
      session_key_hash: Digest::SHA256.digest(session_key),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: "MANAGEMENT_ACCESS",
      expires_at: 1.hour.from_now,
      last_seen_at: Time.current
    )
    cookies[AdminAuth::DEVICE_COOKIE] = device
    cookies[AdminAuth::SESSION_COOKIE] = session_key
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
