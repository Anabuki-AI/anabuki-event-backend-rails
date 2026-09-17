require "rails_helper"

RSpec.describe "Participant quiz answers", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  after { travel_back }
  around do |example|
    with_env("PUBLIC_BASE_URL" => "https://event.example") do
      host! "event.example"
      https!
      example.run
    end
  end

  let!(:question) do
    Question.create!(
      position: 1,
      question_text: "Question 1",
      choice_a: "choice A",
      choice_b: "choice B",
      choice_c: "choice C",
      choice_d: "choice D",
      correct_answer: "B"
    )
  end

  let(:participant) do
    Participant.create!(
      display_name: "Player",
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
  end

  let(:origin_headers) { { "Origin" => "https://event.example" } }

  before do
    sign_in(participant)
    QuizSession.current.start!
  end

  def sign_in(participant)
    raw_token = SecureRandom.urlsafe_base64(32, false)
    ParticipantSession.create!(
      participant:,
      token_hash: Digest::SHA256.digest(raw_token),
      expires_at: 1.hour.from_now
    )
    cookies["participant_session"] = raw_token
  end

  def submit_answer(choice: "B", confidence_level: "high", question_id: nil)
    post "/api/participant/quiz/answers",
      params: { question_id: question_id || question.id, choice:, confidence_level: },
      headers: origin_headers,
      as: :json
  end

  it "records an answer with awarded points and returns my_answer with 201" do
    expect {
      submit_answer(choice: "B", confidence_level: "high")
    }.to change(ParticipantAnswer, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to eq(
      "answered" => true,
      "my_answer" => { "choice" => "B", "confidence_level" => "high" }
    )
    answer = ParticipantAnswer.sole
    expect(answer).to have_attributes(
      participant:,
      question:,
      choice: "B",
      confidence_level: "high",
      awarded_points: 200
    )
  end

  it "uses the question's configured points when scoring an answer" do
    question.update!(points: 250)

    submit_answer(choice: "B", confidence_level: "high")

    expect(ParticipantAnswer.sole.awarded_points).to eq(500)
  end

  it "stores zero points for an incorrect answer" do
    submit_answer(choice: "A", confidence_level: "low")

    expect(ParticipantAnswer.sole.awarded_points).to eq(0)
  end

  it "uses the configured confidence multiplier for awarded points" do
    ConfidenceMultiplier.all_levels
    ConfidenceMultiplier.find_by!(level: "low").update!(confidence_multiplier: BigDecimal("0.75"))

    submit_answer(choice: "B", confidence_level: "low")

    expect(ParticipantAnswer.sole.awarded_points).to eq(75)
  end

  it "overwrites a previous answer for the same question (idempotent)" do
    submit_answer(choice: "A", confidence_level: "high")

    expect {
      submit_answer(choice: "B", confidence_level: "normal")
    }.not_to change(ParticipantAnswer, :count)

    expect(response).to have_http_status(:created)
    answer = ParticipantAnswer.sole
    expect(answer).to have_attributes(choice: "B", confidence_level: "normal", awarded_points: 100)
  end

  it "reports answered and my_answer in the state endpoint after answering" do
    submit_answer(choice: "C", confidence_level: "low")

    get "/api/participant/quiz/state"

    body = response.parsed_body
    expect(body["answered"]).to be(true)
    expect(body["my_answer"]).to eq("choice" => "C", "confidence_level" => "low")
    expect(body["correct_answer"]).to be_nil
  end

  it "rejects answers after the server-side time limit and closes the window" do
    question.update!(time_limit_seconds: 1)

    travel_to(QuizSession.current.reload.phase_started_at + 2.seconds) do
      expect {
        submit_answer
      }.not_to change(ParticipantAnswer, :count)

      expect(response).to have_http_status(:conflict)
      expect(QuizSession.current.reload.phase).to eq("closed")
    end
  end

  it "rejects answers outside the answering phase with 409" do
    QuizSession.current.close!

    expect {
      submit_answer
    }.not_to change(ParticipantAnswer, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to be_present
  end

  it "rejects answers for a question that is not the current one with 409" do
    other = Question.create!(
      position: 2,
      question_text: "Question 2",
      choice_a: "choice A",
      choice_b: "choice B",
      choice_c: "choice C",
      choice_d: "choice D",
      correct_answer: "A"
    )

    expect {
      submit_answer(question_id: other.id)
    }.not_to change(ParticipantAnswer, :count)

    expect(response).to have_http_status(:conflict)
  end

  it "rejects invalid choices and unknown confidence levels without recording an answer" do
    expect {
      submit_answer(choice: "E")
    }.not_to change(ParticipantAnswer, :count)
    expect(response).to have_http_status(:unprocessable_content)

    expect {
      submit_answer(confidence_level: "mega")
    }.not_to change(ParticipantAnswer, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "does not leak the correct answer before reveal even after answering" do
    QuizSession.current.close!

    get "/api/participant/quiz/state"

    expect(response.parsed_body["correct_answer"]).to be_nil
  end

  it "requires a participant session and a same-origin POST" do
    unknown_token = SecureRandom.urlsafe_base64(32, false)
    cookies["participant_session"] = unknown_token
    post "/api/participant/quiz/answers",
      params: { question_id: question.id, choice: "A", confidence_level: "high" },
      headers: origin_headers,
      as: :json
    expect(response).to have_http_status(:unauthorized)

    sign_in(participant)
    post "/api/participant/quiz/answers",
      params: { question_id: question.id, choice: "A", confidence_level: "high" },
      headers: { "Origin" => "https://untrusted.example" },
      as: :json
    expect(response).to have_http_status(:forbidden)
    expect(ParticipantAnswer.count).to eq(0)
  end
end
