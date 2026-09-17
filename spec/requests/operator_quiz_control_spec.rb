require "rails_helper"

RSpec.describe "Operator quiz control", type: :request do
  include ActiveSupport::Testing::TimeHelpers

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
        "phase_started_at" => nil,
        "finished_elapsed_seconds" => nil,
        "current" => nil,
        "next_question" => nil,
        "question_count" => 1,
        "total_participants" => 0
      )
    end

    it "returns the current question with operator-only fields while in progress" do
      authenticate_operator(manager_enabled: true)
      question = create_question(position: 1, correct_answer: "B", time_limit_seconds: 30)
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
      expect(body["phase_started_at"]).to be_present
      expect(body["finished_elapsed_seconds"]).to be_nil
      expect(Time.iso8601(body["phase_started_at"])).to be_within(5.seconds).of(Time.current)
      expect(body["current"]).to eq(
        "question_id" => question.id,
        "position" => 1,
        "question_text" => "Question 1",
        "choices" => { "A" => "choice A", "B" => "choice B", "C" => "choice C", "D" => "choice D" },
        "image_url" => nil,
        "correct_answer" => "B",
        "time_limit_seconds" => 30,
        "answered_count" => 0,
        "answered_rate" => 0.0
      )
      expect(body["next_question"]).to be_nil
    end

    it "supports a nil time_limit_seconds (no timer) for backward compatibility" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      QuizSession.current.start!

      get "/api/operator/quiz/state"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["current"]["time_limit_seconds"]).to be_nil
    end

    it "includes a next_question preview without the correct answer when a next question exists" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      second = create_question(position: 2, correct_answer: "C")
      QuizSession.current.start!

      get "/api/operator/quiz/state"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["next_question"]).to eq(
        "question_id" => second.id,
        "position" => 2,
        "question_text" => "Question 2",
        "choices" => { "A" => "choice A", "B" => "choice B", "C" => "choice C", "D" => "choice D" },
        "image_url" => nil
      )
    end

    it "exposes attached images through the scoped operator quiz route" do
      authenticate_operator(manager_enabled: true)
      question = create_question(position: 1)
      question.image.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/question.webp")),
        filename: "question.webp",
        content_type: "image/webp"
      )
      QuizSession.current.start!

      get "/api/operator/quiz/state"

      expect(response.parsed_body.dig("current", "image_url")).to eq("/operator/quiz/questions/#{question.id}/image")
      get "/api/operator/quiz/questions/#{question.id}/image"
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/webp")
    end

    it "returns a nil next_question on the final question" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      QuizSession.current.start!

      get "/api/operator/quiz/state"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["next_question"]).to be_nil
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

    it "accepts the configured admin origin for an admin management session" do
      authenticate_admin
      create_question(position: 1)

      post "/api/operator/quiz/start", headers: { "Origin" => "https://event.example" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["phase"]).to eq("answering")
    end

    it "requires the configured origin for every state-changing action" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      bad_headers = { "Origin" => "https://untrusted.example.invalid" }

      post "/api/operator/quiz/start", headers: bad_headers, as: :json
      expect(response).to have_http_status(:forbidden)
      post "/api/operator/quiz/publish", headers: bad_headers, as: :json
      expect(response).to have_http_status(:forbidden)
      post "/api/operator/quiz/close", headers: bad_headers, as: :json
      expect(response).to have_http_status(:forbidden)
      post "/api/operator/quiz/reveal", headers: bad_headers, as: :json
      expect(response).to have_http_status(:forbidden)
      post "/api/operator/quiz/finish", headers: bad_headers, as: :json
      expect(response).to have_http_status(:forbidden)
      post "/api/operator/quiz/reset", headers: bad_headers, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(QuizSession.current.status).to eq("waiting")
    end
  end

  describe "POST /api/operator/quiz/publish" do
    it "publishes the next real question and resets the phase to answering" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      second = create_question(position: 2)
      QuizSession.current.start!
      QuizSession.current.close!

      post "/api/operator/quiz/publish", headers: operator_headers, as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["phase"]).to eq("answering")
      expect(body["current"]["question_id"]).to eq(second.id)
    end

    it "selects the next real position when a question was deleted" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      deleted = create_question(position: 2)
      third = create_question(position: 3)
      deleted.destroy!
      QuizSession.current.start!
      QuizSession.current.reveal!

      post "/api/operator/quiz/publish", headers: operator_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["current"].slice("question_id", "position")).to eq(
        "question_id" => third.id, "position" => 3
      )
    end

    it "rejects publish when there are no more questions" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      QuizSession.current.start!

      post "/api/operator/quiz/publish", headers: operator_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects publish while waiting with 422" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)

      post "/api/operator/quiz/publish", headers: operator_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/operator/quiz/close and reveal" do
    it "starts a ten-second closing countdown instead of closing immediately" do
      authenticate_operator(manager_enabled: true)
      question = create_question(position: 1)
      QuizSession.current.start!
      scheduled = instance_double(ActiveJob::ConfiguredJob, perform_later: true)
      allow(CloseQuizAnswersJob).to receive(:set).and_return(scheduled)

      post "/api/operator/quiz/close", headers: operator_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["phase"]).to eq("closing")
      expect(response.parsed_body["phase_started_at"]).to be_present
      expect(CloseQuizAnswersJob).to have_received(:set).with(wait_until: be_within(1.second).of(10.seconds.from_now))
      expect(scheduled).to have_received(:perform_later).with(question.id, a_string_matching(/T/))
    end

    it "rejects another close and answer reveal while the countdown is running" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      QuizSession.current.start!
      allow(CloseQuizAnswersJob).to receive(:set).and_return(instance_double(ActiveJob::ConfiguredJob, perform_later: true))

      post "/api/operator/quiz/close", headers: operator_headers, as: :json
      post "/api/operator/quiz/close", headers: operator_headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      post "/api/operator/quiz/reveal", headers: operator_headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "can reveal after the delayed close is finalized" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      QuizSession.current.start!
      QuizSession.current.close!

      post "/api/operator/quiz/reveal", headers: operator_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["phase"]).to eq("revealed")
    end

    it "rejects close while waiting with 422" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)

      post "/api/operator/quiz/close", headers: operator_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/operator/quiz/finish" do
    it "finishes from in_progress and keeps the final elapsed seconds across later reads" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      started_at = Time.current.change(usec: 0)
      travel_to(started_at) { QuizSession.current.start! }

      travel_to(started_at + 7.seconds) do
        post "/api/operator/quiz/finish", headers: operator_headers, as: :json
      end

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["status"]).to eq("finished")
      expect(body["phase"]).to be_nil
      expect(body["current"]).to be_nil
      expect(body["finished_elapsed_seconds"]).to eq(7)

      travel_to(started_at + 10.minutes) do
        get "/api/operator/quiz/state"
      end
      expect(response.parsed_body["finished_elapsed_seconds"]).to eq(7)
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

  describe "POST /api/operator/quiz/reset" do
    it "forces the session back to waiting and clears participant answers regardless of current state" do
      authenticate_operator(manager_enabled: true)
      question = create_question(position: 1)
      participant = create_participant
      QuizSession.current.start!
      ParticipantAnswer.create!(participant:, question:, choice: "A", confidence_level: "normal")

      post "/api/operator/quiz/reset", headers: operator_headers, as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["status"]).to eq("waiting")
      expect(body["phase"]).to be_nil
      expect(body["current"]).to be_nil
      expect(ParticipantAnswer.count).to eq(0)
    end

    it "succeeds even from the waiting state" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)

      post "/api/operator/quiz/reset", headers: operator_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("waiting")
    end

    it "succeeds after finishing" do
      authenticate_operator(manager_enabled: true)
      create_question(position: 1)
      QuizSession.current.start!
      QuizSession.current.finish!

      post "/api/operator/quiz/reset", headers: operator_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("waiting")
      expect(response.parsed_body["finished_elapsed_seconds"]).to be_nil
    end

    it "rejects reset outside development and test environments without mutating state" do
      authenticate_operator(manager_enabled: true)
      question = create_question(position: 1)
      participant = create_participant
      QuizSession.current.start!
      ParticipantAnswer.create!(participant:, question:, choice: "A", confidence_level: "normal")
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:test?).and_return(false)

      post "/api/operator/quiz/reset", headers: operator_headers, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(QuizSession.current.reload.status).to eq("in_progress")
      expect(ParticipantAnswer.count).to eq(1)
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

  def create_question(position:, correct_answer: "A", time_limit_seconds: nil)
    Question.create!(
      position:,
      question_text: "Question #{position}",
      choice_a: "choice A",
      choice_b: "choice B",
      choice_c: "choice C",
      choice_d: "choice D",
      correct_answer:,
      time_limit_seconds:
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
