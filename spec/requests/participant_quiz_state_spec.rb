require "rails_helper"

RSpec.describe "Participant quiz state", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  around do |example|
    host! "localhost"
    example.run
  end

  let!(:question) { create_question(position: 1, correct_answer: "B") }

  def participant_cookie
    participant = Participant.create!(
      display_name: "Player",
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
    raw_token = SecureRandom.urlsafe_base64(32, false)
    ParticipantSession.create!(
      participant:,
      token_hash: Digest::SHA256.digest(raw_token),
      expires_at: 1.hour.from_now
    )
    raw_token
  end

  def sign_in
    raw_token = participant_cookie
    cookies["participant_session"] = raw_token
  end

  it "requires a participant session" do
    get "/api/participant/quiz/state"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "Participant session is required")
  end

  it "returns only the status while waiting" do
    sign_in

    get "/api/participant/quiz/state"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "waiting")
  end

  it "returns only the status while finished" do
    sign_in
    QuizSession.current.finish!

    get "/api/participant/quiz/state"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "finished")
  end

  it "returns the current question without the correct answer while answering" do
    sign_in
    QuizSession.current.start!

    get "/api/participant/quiz/state"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      "status" => "in_progress",
      "phase" => "answering",
      "phase_started_at" => QuizSession.current.reload.phase_started_at.iso8601,
      "question" => {
        "question_id" => question.id,
        "position" => 1,
        "question_text" => "Question 1",
        "target_audience" => nil,
        "choices" => { "A" => "choice A", "B" => "choice B", "C" => "choice C", "D" => "choice D" },
        "eliminated_choice" => nil,
        "is_live_relay_question" => false,
        "image_url" => nil
      },
      "answered" => false,
      "my_answer" => nil,
      "correct_answer" => nil,
      "explanation" => nil,
      "confidence_level" => nil,
      "confidence_locked" => false,
      "confidence_multipliers" => { "high" => 2.0, "normal" => 1.0, "low" => 0.5 }
    )
  end

  it "exposes the target audience alongside the question text" do
    sign_in
    question.update!(target_audience: "1年生チーム")
    QuizSession.current.start!

    get "/api/participant/quiz/state"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("question", "target_audience")).to eq("1年生チーム")
  end

  it "marks a selected relay question as live for participants" do
    sign_in
    question.update!(is_relay_question: true, is_selected_relay_question: true)
    QuizSession.current.start!

    get "/api/participant/quiz/state"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("question", "is_live_relay_question")).to be(true)
  end

  it "exposes an attached image only through the current participant quiz route" do
    question.image.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/question.webp")),
      filename: "question.webp",
      content_type: "image/webp"
    )
    sign_in
    QuizSession.current.start!

    get "/api/participant/quiz/state"
    image_url = response.parsed_body.dig("question", "image_url")
    expect(image_url).to eq("/participant/quiz/questions/#{question.id}/image")

    get "/api#{image_url}"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/webp")
    expect(response.body).to eq(File.binread(Rails.root.join("spec/fixtures/files/question.webp")))
  end

  it "does not serve an attached image for a non-current question" do
    question.image.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/question.webp")),
      filename: "question.webp",
      content_type: "image/webp"
    )
    other = create_question(position: 2, correct_answer: "A")
    sign_in
    QuizSession.current.start!

    get "/api/participant/quiz/questions/#{other.id}/image"

    expect(response).to have_http_status(:not_found)
  end

  it "exposes the server-started ten-second closing countdown without the correct answer" do
    sign_in
    QuizSession.current.start!
    scheduled = instance_double(ActiveJob::ConfiguredJob, perform_later: true)
    allow(CloseQuizAnswersJob).to receive(:set).and_return(scheduled)
    QuizSession.current.request_close!

    get "/api/participant/quiz/state"

    expect(response.parsed_body["phase"]).to eq("closing")
    expect(response.parsed_body["phase_started_at"]).to eq(QuizSession.current.reload.phase_started_at.iso8601)
    expect(response.parsed_body["correct_answer"]).to be_nil
  end

  it "finalizes an expired countdown on polling without a worker or answers" do
    sign_in
    QuizSession.current.start!
    allow(CloseQuizAnswersJob).to receive(:set).and_return(instance_double(ActiveJob::ConfiguredJob, perform_later: true))
    QuizSession.current.request_close!
    deadline = QuizSession.current.phase_started_at + 10.seconds

    travel_to(deadline - 1.second, with_usec: true) do
      get "/api/participant/quiz/state"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["phase"]).to eq("closing")
    end
    travel_to(deadline, with_usec: true) do
      get "/api/participant/quiz/state"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("phase" => "closed", "correct_answer" => nil, "answered" => false)
      expect(QuizSession.current.phase_started_at).to eq(deadline)
    end
    travel_to(deadline + 1.minute, with_usec: true) do
      get "/api/participant/quiz/state"
      expect(response.parsed_body["phase"]).to eq("closed")
      expect(QuizSession.current.phase_started_at).to eq(deadline)
    end
  end

  it "finalizes a configured timer on polling without an operator or worker" do
    sign_in
    question.update!(time_limit_seconds: 5)
    QuizSession.current.start!
    deadline = QuizSession.current.answering_started_at + 5.seconds

    travel_to(deadline, with_usec: true) do
      get "/api/participant/quiz/state"
      expect(response.parsed_body["phase"]).to eq("closed")
      expect(QuizSession.current.phase_started_at).to eq(deadline)
    end
  end

  it "hides the correct answer while closed" do
    sign_in
    question.update!(time_limit_seconds: 30)
    QuizSession.current.start!

    travel_to(QuizSession.current.answering_started_at + 30.seconds, with_usec: true) do
      QuizSession.current.close!
      get "/api/participant/quiz/state"

      expect(response.parsed_body["phase"]).to eq("closed")
      expect(response.parsed_body["correct_answer"]).to be_nil
    end
  end

  it "exposes the correct answer only while revealed" do
    sign_in
    QuizSession.current.start!
    QuizSession.current.reveal!

    get "/api/participant/quiz/state"

    expect(response.parsed_body["phase"]).to eq("revealed")
    expect(response.parsed_body["correct_answer"]).to eq("B")
  end

  it "exposes the explanation only while revealed" do
    sign_in
    question.update!(explanation: "Because B is right.")
    QuizSession.current.start!

    get "/api/participant/quiz/state"
    expect(response.parsed_body["explanation"]).to be_nil

    QuizSession.current.reveal!
    get "/api/participant/quiz/state"
    expect(response.parsed_body["explanation"]).to eq("Because B is right.")
  end

  private

  def create_question(position:, correct_answer:, target_audience: nil)
    Question.create!(
      position:,
      question_text: "Question #{position}",
      choice_a: "choice A",
      choice_b: "choice B",
      choice_c: "choice C",
      choice_d: "choice D",
      correct_answer:,
      target_audience:
    )
  end
end
