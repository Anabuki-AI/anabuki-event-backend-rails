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
      "confidence_multipliers" => { "high" => 2.0, "normal" => 1.0, "low" => 0.5 }
    )
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
