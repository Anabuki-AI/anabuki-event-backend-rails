require "rails_helper"

RSpec.describe "Participant and operator quiz APIs", type: :request do
  around do |example|
    with_env(
      "PUBLIC_BASE_URL" => "https://event.example",
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

  it "requires the appropriate participant and manager sessions" do
    get "/api/participant/quiz/state"
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "Participant session is required")

    get "/api/operator/quiz/state"
    expect(response).to have_http_status(:unauthorized)

    authenticate_operator("APPLICANT")
    get "/api/operator/quiz/state"
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "Manager access is required")
  end

  it "snapshots the quiz, accepts one published answer, and never exposes scoring before reveal" do
    first = Question.create!(question_attributes(position: 1, correct_answer: "A"))
    Question.create!(question_attributes(position: 2, question_text: "Second", correct_answer: "B"))
    ConfidenceMultiplier.all_levels.fetch("high").update!(confidence_multiplier: 2)
    authenticate_operator("MANAGER")

    post "/api/operator/quiz/start", headers: same_origin_headers
    expect(response).to have_http_status(:created)
    started = response.parsed_body
    expect(started.dig("event", "confidenceMultipliers")).to include("high" => "2.00")
    expect(started.fetch("questions").map { |question| question.fetch("status") }).to eq(%w[PENDING PENDING])

    # These changes affect the question bank, not the in-progress event.
    first.update!(question_text: "Changed after start")
    ConfidenceMultiplier.all_levels.fetch("high").update!(confidence_multiplier: 9.99)

    authenticate_participant
    get "/api/participant/quiz/state"
    expect(response).to have_http_status(:ok)
    expect(response.headers.fetch("Cache-Control")).to eq("no-store")
    expect(response.parsed_body).to include(
      "event" => include("revealedQuestionCount" => 0, "confidenceMultipliers" => include("high" => "2.00")),
      "question" => nil
    )
    expect(response.parsed_body.fetch("event")).not_to have_key("totalScore")

    post "/api/operator/quiz/publish", headers: same_origin_headers
    expect(response).to have_http_status(:ok)

    get "/api/participant/quiz/state"
    published_question = response.parsed_body.fetch("question")
    expect(published_question).to include("status" => "PUBLISHED", "questionText" => "Question")
    expect(published_question).not_to have_key("correctAnswer")
    expect(published_question.fetch("myAnswer")).to be_nil
    expect(response.parsed_body.fetch("event")).not_to have_key("totalScore")

    question_id = published_question.fetch("id")
    post "/api/participant/quiz/answers", params: { quizEventQuestionId: question_id, answer: "B", confidenceLevel: "high" }, as: :json, headers: same_origin_headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("answer" => "B", "confidenceLevel" => "high")
    expect(response.parsed_body).not_to have_key("isCorrect")
    expect(response.parsed_body).not_to have_key("points")

    post "/api/participant/quiz/answers", params: { quizEventQuestionId: question_id, answer: "A", confidenceLevel: "normal" }, as: :json, headers: same_origin_headers
    expect(response).to have_http_status(:conflict)
    expect(QuizAnswer.count).to eq(1)

    post "/api/operator/quiz/close", headers: same_origin_headers
    post "/api/participant/quiz/answers", params: { quizEventQuestionId: question_id, answer: "A", confidenceLevel: "normal" }, as: :json, headers: same_origin_headers
    expect(response).to have_http_status(:conflict)

    post "/api/operator/quiz/reveal", headers: same_origin_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("questions").first).to include("status" => "REVEALED", "correctAnswer" => "A")

    get "/api/participant/quiz/state"
    revealed = response.parsed_body
    expect(revealed.dig("question", "correctAnswer")).to eq("A")
    expect(revealed.dig("question", "myAnswer")).to include("isCorrect" => false, "points" => "0.00")
    expect(revealed.dig("event", "totalScore")).to eq("0.00")

    post "/api/operator/quiz/publish", headers: same_origin_headers
    second_question_id = response.parsed_body.fetch("questions").second.fetch("id")
    post "/api/participant/quiz/answers", params: { quizEventQuestionId: second_question_id, answer: "B", confidenceLevel: "high" }, as: :json, headers: same_origin_headers
    expect(response).to have_http_status(:created)

    # reveal can move a currently published question directly to REVEALED.
    post "/api/operator/quiz/reveal", headers: same_origin_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("event", "status")).to eq("FINISHED")

    get "/api/participant/quiz/state"
    expect(response.parsed_body.dig("event", "status")).to eq("FINISHED")
    expect(response.parsed_body.dig("event", "totalScore")).to eq("200.00")
    expect(response.parsed_body.dig("question", "myAnswer")).to include("isCorrect" => true, "points" => "200.00")
  end

  it "maps unique-index answer races to an idempotent response or a conflict" do
    Question.create!(question_attributes(position: 1))
    authenticate_operator("MANAGER")
    post "/api/operator/quiz/start", headers: same_origin_headers
    post "/api/operator/quiz/publish", headers: same_origin_headers

    participant = authenticate_participant
    question = QuizEventQuestion.sole
    existing_answer = QuizAnswer.create!(
      participant:,
      quiz_event_question: question,
      answer: "A",
      confidence_level: "high",
      multiplier_snapshot: 2,
      is_correct: true,
      score: 200
    )

    # Simulate a second request that checked before the first transaction
    # committed. The unique database index, rather than a model validation,
    # then raises RecordNotUnique on create.
    allow(QuizAnswer).to receive(:lock).and_return(QuizAnswer.none)

    post "/api/participant/quiz/answers", params: { quizEventQuestionId: question.id, answer: "A", confidenceLevel: "high" }, as: :json, headers: same_origin_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => existing_answer.id, "answer" => "A", "confidenceLevel" => "high")

    post "/api/participant/quiz/answers", params: { quizEventQuestionId: question.id, answer: "B", confidenceLevel: "normal" }, as: :json, headers: same_origin_headers
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("error" => "An answer has already been submitted")
  end

  it "rejects invalid quiz lifecycle transitions" do
    authenticate_operator("MANAGER")

    post "/api/operator/quiz/start", headers: same_origin_headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "No questions are available")

    Question.create!(question_attributes(position: 1))
    post "/api/operator/quiz/start", headers: same_origin_headers
    expect(response).to have_http_status(:created)

    post "/api/operator/quiz/start", headers: same_origin_headers
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("error" => "A quiz event is already active")

    post "/api/operator/quiz/close", headers: same_origin_headers
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("error" => "No published question is available")

    post "/api/operator/quiz/reveal", headers: same_origin_headers
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("error" => "No published or closed question is available")

    post "/api/operator/quiz/publish", headers: same_origin_headers
    expect(response).to have_http_status(:ok)
    post "/api/operator/quiz/close", headers: same_origin_headers
    expect(response).to have_http_status(:ok)

    post "/api/operator/quiz/publish", headers: same_origin_headers
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("error" => "The closed question must be revealed before publishing another")
  end

  it "protects quiz mutations with the existing origin rules and validates answer input" do
    Question.create!(question_attributes(position: 1))
    authenticate_operator("MANAGER")

    post "/api/operator/quiz/start", headers: { "Origin" => "https://attacker.example" }
    expect(response).to have_http_status(:forbidden)
    expect(QuizEvent.count).to eq(0)

    post "/api/operator/quiz/start", headers: same_origin_headers
    post "/api/operator/quiz/publish", headers: same_origin_headers
    authenticate_participant
    question_id = QuizEventQuestion.sole.id

    post "/api/participant/quiz/answers", params: { quizEventQuestionId: question_id, answer: "E", confidenceLevel: "sure" }, as: :json, headers: same_origin_headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(QuizAnswer.count).to eq(0)

    post "/api/participant/quiz/answers", params: { quizEventQuestionId: question_id, answer: "A", confidenceLevel: "normal" }, as: :json, headers: { "Origin" => "https://attacker.example" }
    expect(response).to have_http_status(:forbidden)
    expect(QuizAnswer.count).to eq(0)
  end

  private

  def question_attributes(position:, question_text: "Question", correct_answer: "A")
    {
      position:,
      question_text:,
      choice_a: "A choice",
      choice_b: "B choice",
      choice_c: "C choice",
      choice_d: "D choice",
      correct_answer:
    }
  end

  def authenticate_operator(source)
    identity = Operator::Identity.create!(email: "#{source.downcase}-#{SecureRandom.uuid}@example.com", google_sub: SecureRandom.uuid)
    device = SecureRandom.urlsafe_base64(32, false)
    session_key = SecureRandom.urlsafe_base64(32, false)
    Operator::DeviceSession.create!(
      operator_identity: identity,
      device_id_hash: Digest::SHA256.digest(device),
      session_key_hash: Digest::SHA256.digest(session_key),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: source,
      expires_at: 1.hour.from_now,
      last_seen_at: Time.current
    )
    cookies[OperatorAuth::DEVICE_COOKIE] = device
    cookies[source == "MANAGER" ? OperatorAuth::SESSION_COOKIE : OperatorAuth::APPLICANT_SESSION_COOKIE] = session_key
  end

  def authenticate_participant
    participant = Participant.create!(
      display_name: "Player", gender: "no_answer", age_group: "20s", student_type: "not_student", agreed_terms: true
    )
    token = SecureRandom.urlsafe_base64(32, false)
    ParticipantSession.create!(participant:, token_hash: Digest::SHA256.digest(token), expires_at: 1.hour.from_now)
    cookies[ParticipantAuth::SESSION_COOKIE] = token
    participant
  end

  def same_origin_headers
    { "Origin" => "https://event.example" }
  end
end
