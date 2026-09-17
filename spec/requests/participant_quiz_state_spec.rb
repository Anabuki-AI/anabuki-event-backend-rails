require "rails_helper"

RSpec.describe "Participant quiz state", type: :request do
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
        "choices" => { "A" => "choice A", "B" => "choice B", "C" => "choice C", "D" => "choice D" },
        "image_url" => nil
      },
      "answered" => false,
      "my_answer" => nil,
      "correct_answer" => nil,
      "confidence_level" => nil,
      "confidence_locked" => false,
      "confidence_multipliers" => { "high" => 2.0, "normal" => 1.0, "low" => 0.5 }
    )
  end

  it "exposes an attached image only through the current participant quiz route" do
    question.image.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/question.png")),
      filename: "question.png",
      content_type: "image/png"
    )
    sign_in
    QuizSession.current.start!

    get "/api/participant/quiz/state"
    image_url = response.parsed_body.dig("question", "image_url")
    expect(image_url).to eq("/participant/quiz/questions/#{question.id}/image")

    get "/api#{image_url}"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/png")
    expect(response.body).to eq(File.binread(Rails.root.join("spec/fixtures/files/question.png")))
  end

  it "does not serve an attached image for a non-current question" do
    question.image.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/question.png")),
      filename: "question.png",
      content_type: "image/png"
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

  it "hides the correct answer while closed" do
    sign_in
    QuizSession.current.start!
    QuizSession.current.close!

    get "/api/participant/quiz/state"

    expect(response.parsed_body["phase"]).to eq("closed")
    expect(response.parsed_body["correct_answer"]).to be_nil
  end

  it "exposes the correct answer only while revealed" do
    sign_in
    QuizSession.current.start!
    QuizSession.current.reveal!

    get "/api/participant/quiz/state"

    expect(response.parsed_body["phase"]).to eq("revealed")
    expect(response.parsed_body["correct_answer"]).to eq("B")
  end

  private

  def create_question(position:, correct_answer:)
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
end
