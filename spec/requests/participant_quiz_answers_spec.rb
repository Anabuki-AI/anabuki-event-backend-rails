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

  def confirm_confidence(level, question_id: question.id)
    post "/api/participant/quiz/confidence-level",
      params: { question_id:, confidence_level: level },
      headers: origin_headers,
      as: :json
  end

  def submit_answer(choice: "B", question_id: question.id)
    post "/api/participant/quiz/answers",
      params: { question_id:, choice: },
      headers: origin_headers,
      as: :json
  end

  it "requires a locked confidence level before recording an answer" do
    expect {
      submit_answer
    }.not_to change(ParticipantAnswer, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to include("confidence")
  end

  it "locks a confidence level once, and accepts an identical retry" do
    confirm_confidence("normal")

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "confidence_level" => "normal",
      "confidence_locked" => true
    )
    expect(ParticipantQuizConfidenceSelection.sole).to have_attributes(
      participant:,
      question:,
      confidence_level: "normal",
      eliminated_choice: nil
    )

    expect {
      confirm_confidence("normal")
    }.not_to change(ParticipantQuizConfidenceSelection, :count)
    expect(response).to have_http_status(:ok)

    confirm_confidence("high")
    expect(response).to have_http_status(:conflict)
  end

  it "removes one incorrect choice only for the participant who locks Lv.1" do
    confirm_confidence("low")

    expect(response).to have_http_status(:ok)
    selection = ParticipantQuizConfidenceSelection.sole
    expect(selection.eliminated_choice).to be_in(%w[A C D])
    expect(response.parsed_body.dig("question", "choices").keys).to contain_exactly(*(%w[A B C D] - [ selection.eliminated_choice ]))
    expect(response.parsed_body.dig("question", "choices")).to include("B" => "choice B")
  end

  it "rejects an Lv.1-eliminated choice without recording an answer" do
    confirm_confidence("low")
    eliminated_choice = ParticipantQuizConfidenceSelection.sole.eliminated_choice

    expect {
      submit_answer(choice: eliminated_choice)
    }.not_to change(ParticipantAnswer, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to include("eliminated")
  end

  it "uses the question's configured points and locked multiplier for a correct answer" do
    question.update!(points: 250)
    confirm_confidence("high")

    submit_answer(choice: "B")

    expect(ParticipantAnswer.sole.awarded_points).to eq(500)
  end

  it "records a correct answer using the locked level's configured multiplier" do
    ConfidenceMultiplier.all_levels
    ConfidenceMultiplier.find_by!(level: "low").update!(confidence_multiplier: BigDecimal("0.75"))
    confirm_confidence("low")

    expect {
      submit_answer(choice: "B")
    }.to change(ParticipantAnswer, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to eq(
      "answered" => true,
      "my_answer" => { "choice" => "B", "confidence_level" => "low" }
    )
    expect(ParticipantAnswer.sole).to have_attributes(
      participant:,
      question:,
      choice: "B",
      confidence_level: "low",
      awarded_points: 75
    )
  end

  it "deducts half of the question points for an incorrect Lv.3 answer" do
    question.update!(points: 101)
    confirm_confidence("high")

    submit_answer(choice: "A")

    expect(response).to have_http_status(:created)
    expect(ParticipantAnswer.sole).to have_attributes(confidence_level: "high", awarded_points: -51)
  end

  it "keeps incorrect Lv.1 and Lv.2 answers at zero points" do
    confirm_confidence("normal")
    submit_answer(choice: "A")

    expect(ParticipantAnswer.sole.awarded_points).to eq(0)
  end

  it "does not allow a recorded answer to be changed, while accepting an identical retry" do
    confirm_confidence("high")
    submit_answer(choice: "B")

    expect {
      submit_answer(choice: "B")
    }.not_to change(ParticipantAnswer, :count)
    expect(response).to have_http_status(:created)

    submit_answer(choice: "A")
    expect(response).to have_http_status(:conflict)
    expect(ParticipantAnswer.sole).to have_attributes(choice: "B", confidence_level: "high", awarded_points: 200)
  end

  it "reports the locked level and my_answer in the state endpoint" do
    confirm_confidence("normal")
    submit_answer(choice: "C")

    get "/api/participant/quiz/state"

    body = response.parsed_body
    expect(body).to include("confidence_level" => "normal", "confidence_locked" => true, "answered" => true)
    expect(body["my_answer"]).to eq("choice" => "C", "confidence_level" => "normal")
    expect(body["correct_answer"]).to be_nil
  end

  it "rejects answers after the server-side time limit and closes the window" do
    question.update!(time_limit_seconds: 1)
    confirm_confidence("normal")

    travel_to(QuizSession.current.reload.phase_started_at + 2.seconds) do
      expect {
        submit_answer
      }.not_to change(ParticipantAnswer, :count)

      expect(response).to have_http_status(:conflict)
      expect(QuizSession.current.reload.phase).to eq("closed")
    end
  end

  it "keeps the original question time limit while the closing countdown runs" do
    question.update!(time_limit_seconds: 1)
    confirm_confidence("normal")
    scheduled = instance_double(ActiveJob::ConfiguredJob, perform_later: true)
    allow(CloseQuizAnswersJob).to receive(:set).and_return(scheduled)
    QuizSession.current.request_close!

    travel_to(QuizSession.current.reload.answering_started_at + 2.seconds) do
      expect {
        submit_answer
      }.not_to change(ParticipantAnswer, :count)

      expect(response).to have_http_status(:conflict)
      expect(QuizSession.current.reload.phase).to eq("closed")
    end
  end

  it "continues accepting a locked-level answer during the operator's ten-second closing countdown" do
    confirm_confidence("normal")
    scheduled = instance_double(ActiveJob::ConfiguredJob, perform_later: true)
    allow(CloseQuizAnswersJob).to receive(:set).and_return(scheduled)
    QuizSession.current.request_close!

    expect {
      submit_answer
    }.to change(ParticipantAnswer, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(QuizSession.current.reload.phase).to eq("closing")
  end

  it "rejects confidence locks and answers outside the answering phase" do
    QuizSession.current.close!

    expect {
      confirm_confidence("high")
    }.not_to change(ParticipantQuizConfidenceSelection, :count)
    expect(response).to have_http_status(:conflict)

    expect {
      submit_answer
    }.not_to change(ParticipantAnswer, :count)
    expect(response).to have_http_status(:conflict)
  end

  it "rejects invalid levels and choices without recording state" do
    expect {
      confirm_confidence("mega")
    }.not_to change(ParticipantQuizConfidenceSelection, :count)
    expect(response).to have_http_status(:unprocessable_content)

    confirm_confidence("normal")
    expect {
      submit_answer(choice: "E")
    }.not_to change(ParticipantAnswer, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "requires a participant session and a same-origin POST" do
    unknown_token = SecureRandom.urlsafe_base64(32, false)
    cookies["participant_session"] = unknown_token
    post "/api/participant/quiz/confidence-level",
      params: { question_id: question.id, confidence_level: "normal" },
      headers: origin_headers,
      as: :json
    expect(response).to have_http_status(:unauthorized)

    sign_in(participant)
    post "/api/participant/quiz/confidence-level",
      params: { question_id: question.id, confidence_level: "normal" },
      headers: { "Origin" => "https://untrusted.example" },
      as: :json
    expect(response).to have_http_status(:forbidden)
    expect(ParticipantQuizConfidenceSelection.count).to eq(0)
  end
end
