require "rails_helper"

RSpec.describe "Admin question management", type: :request do
  QuestionManagementSessionFixture = Data.define(:identity, :device, :session_key, :cookie_name)

  around do |example|
    host! "localhost"
    example.run
  end

  it "requires a management session for read endpoints" do
    get "/api/admin/questions"
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.fetch("error")).to eq("Authentication is required")

    authenticate_as(build_session("APPLICANT"))
    get "/api/admin/questions"
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")
  end

  it "creates, orders, shows, updates, and hard-deletes questions" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post_question(question_payload(question_text: "  最初の問題  ", image_url: " https://example.com/one.png "))
    expect(response).to have_http_status(:created)
    first = response.parsed_body
    expect(first).to include(
      "position" => 1, "questionText" => "最初の問題", "choiceA" => "選択肢A",
      "correctAnswer" => "A", "imageUrl" => "https://example.com/one.png", "points" => 100
    )
    expect(first).to include("id", "choiceB", "choiceC", "choiceD", "createdAt", "updatedAt")

    post_question(question_payload(question_text: "次の問題", correct_answer: "B"))
    second = response.parsed_body
    expect(second.fetch("position")).to eq(2)

    get "/api/admin/questions"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.map { |question| question.fetch("id") }).to eq([ first.fetch("id"), second.fetch("id") ])

    get "/api/admin/questions/#{first.fetch("id")}"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("position")).to eq(1)

    put "/api/admin/questions/#{first.fetch("id")}", params: question_payload(question_text: "更新した問題", image_url: nil), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("questionText" => "更新した問題", "position" => 1, "imageUrl" => nil)

    delete "/api/admin/questions/#{first.fetch("id")}", headers: same_origin_headers
    expect(response).to have_http_status(:no_content)
    expect { Question.find(first.fetch("id")) }.to raise_error(ActiveRecord::RecordNotFound)

    get "/api/admin/questions"
    expect(response.parsed_body.map { |question| question.fetch("position") }).to eq([ 2 ])
  end

  it "uploads, serves, and removes a question image alongside explanation and target audience text" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post "/api/admin/questions", params: question_payload.merge(
      explanation: "これは解説です",
      targetAudience: "初級者向け",
      image: fixture_file_upload("question.png", "image/png")
    )
    expect(response).to have_http_status(:created)
    created = response.parsed_body
    expect(created).to include("explanation" => "これは解説です", "targetAudience" => "初級者向け")
    expect(created.fetch("imageUrl")).to eq("/admin/questions/#{created.fetch('id')}/image")

    get "/api#{created.fetch('imageUrl')}"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/png")

    put "/api/admin/questions/#{created.fetch('id')}", params: question_payload.merge(removeImage: "true")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("imageUrl")).to be_nil

    get "/api/admin/questions/#{created.fetch('id')}/image"
    expect(response).to have_http_status(:not_found)
  end

  it "rejects an oversized explanation, target audience, or invalid image upload" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post "/api/admin/questions", params: question_payload.merge(
      explanation: "x" * 501,
      targetAudience: "x" * 101,
      image: fixture_file_upload("notes.txt", "text/plain")
    )

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("fieldErrors")).to include("explanation", "targetAudience", "image")
  end

  it "accepts the PR #16 choices and correctChoice request fields" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post "/api/admin/questions", params: {
      questionText: "旧フォームの問題",
      choices: { A: "一", B: "二", C: "三", D: "四" },
      correctChoice: "C"
    }, as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include(
      "choiceA" => "一", "choiceB" => "二", "choiceC" => "三", "choiceD" => "四", "correctAnswer" => "C"
    )
  end

  it "returns camelCase field errors and leaves an invalid update unchanged" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    question = Question.create!(question_attributes(position: 7))

    put "/api/admin/questions/#{question.id}", params: question_payload(
      question_text: " ", choice_a: " ", choice_b: " ", choice_c: " ", choice_d: " ",
      correct_answer: "Z", image_url: "not-a-url"
    ), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to be_present
    expect(response.parsed_body.fetch("fieldErrors")).to include(
      "questionText", "choiceA", "choiceB", "choiceC", "choiceD", "correctAnswer", "imageUrl"
    )
    expect(question.reload.question_text).to eq("Question")
  end

  it "returns field errors for non-string question JSON values without updating the question" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    question = Question.create!(question_attributes(position: 7))

    put "/api/admin/questions/#{question.id}", params: question_payload(
      question_text: { nested: "object" },
      choice_a: [ "array" ],
      choice_b: 123,
      choice_c: true,
      choice_d: false,
      correct_answer: { nested: "object" },
      image_url: { nested: "object" }
    ), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to be_a(String)
    expect(response.parsed_body.fetch("fieldErrors")).to eq(
      "questionText" => "must be a string",
      "choiceA" => "must be a string",
      "choiceB" => "must be a string",
      "choiceC" => "must be a string",
      "choiceD" => "must be a string",
      "correctAnswer" => "must be a string",
      "imageUrl" => "must be a string"
    )
    expect(question.reload).to have_attributes(
      question_text: "Question", choice_a: "選択肢A", choice_b: "選択肢B",
      choice_c: "選択肢C", choice_d: "選択肢D", correct_answer: "A", image_url: nil
    )
  end

  it "creates and updates a question's points, rejecting out-of-range or non-numeric values" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post "/api/admin/questions", params: question_payload.merge(points: 250), as: :json
    expect(response).to have_http_status(:created)
    created = response.parsed_body
    expect(created.fetch("points")).to eq(250)

    put "/api/admin/questions/#{created.fetch('id')}", params: question_payload.merge(points: 1), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("points")).to eq(1)

    put "/api/admin/questions/#{created.fetch('id')}", params: question_payload.merge(points: 0), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("fieldErrors")).to include("points")

    put "/api/admin/questions/#{created.fetch('id')}", params: question_payload.merge(points: Question::MAX_POINTS + 1), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("fieldErrors")).to include("points")

    put "/api/admin/questions/#{created.fetch('id')}", params: question_payload.merge(points: "not-a-number"), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("fieldErrors")).to eq("points" => "must be a whole number")

    put "/api/admin/questions/#{created.fetch('id')}", params: question_payload.merge(points: { nested: "object" }), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("fieldErrors")).to eq("points" => "must be a whole number")

    # multipart submissions (used when uploading an image) send points as a numeric string.
    post "/api/admin/questions", params: question_payload.merge(points: "75")
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("points")).to eq(75)
  end

  it "creates and updates a question's time_limit_seconds, treating it as optional and nullable" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post_question(question_payload.merge(timeLimitSeconds: nil))
    expect(response).to have_http_status(:created)
    untimed = response.parsed_body
    expect(untimed.fetch("timeLimitSeconds")).to be_nil

    put "/api/admin/questions/#{untimed.fetch('id')}", params: question_payload.merge(timeLimitSeconds: 30), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("timeLimitSeconds")).to eq(30)

    put "/api/admin/questions/#{untimed.fetch('id')}", params: question_payload.merge(timeLimitSeconds: nil), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("timeLimitSeconds")).to be_nil

    put "/api/admin/questions/#{untimed.fetch('id')}", params: question_payload.merge(timeLimitSeconds: 0), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("fieldErrors")).to include("timeLimitSeconds")

    put "/api/admin/questions/#{untimed.fetch('id')}", params: question_payload.merge(timeLimitSeconds: "not-a-number"), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("fieldErrors")).to eq("timeLimitSeconds" => "must be a whole number or null")

    put "/api/admin/questions/#{untimed.fetch('id')}", params: question_payload.merge(timeLimitSeconds: { nested: "object" }), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("fieldErrors")).to eq("timeLimitSeconds" => "must be a whole number or null")

    # multipart submissions (used when uploading an image) send it as a numeric string.
    post "/api/admin/questions", params: question_payload.merge(timeLimitSeconds: "045")
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("timeLimitSeconds")).to eq(45)

    # omitting the field entirely on create leaves it at its nullable default.
    post_question(question_payload)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("timeLimitSeconds")).to be_nil
  end

  it "preserves an omitted timer on update and clears a blank multipart timer" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    post_question(question_payload.merge(timeLimitSeconds: 30))
    question_id = response.parsed_body.fetch("id")

    put "/api/admin/questions/#{question_id}", params: question_payload, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("timeLimitSeconds")).to eq(30)

    put "/api/admin/questions/#{question_id}", params: question_payload.merge(timeLimitSeconds: " ")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("timeLimitSeconds")).to be_nil
  end

  it "rejects invalid timer types and values outside the database integer range" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    post_question(question_payload.merge(timeLimitSeconds: 30))
    question_id = response.parsed_body.fetch("id")

    [ true, [], 1.5, -1, 0, Question::MAX_TIME_LIMIT_SECONDS + 1 ].each do |invalid|
      put "/api/admin/questions/#{question_id}", params: question_payload.merge(timeLimitSeconds: invalid), as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch("fieldErrors")).to include("timeLimitSeconds")
      expect(Question.find(question_id).time_limit_seconds).to eq(30)
    end
  end

  it "enforces same-origin protection and permits PUT/PATCH CORS preflight" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post "/api/admin/questions", params: question_payload, as: :json, headers: { "Origin" => "https://attacker.example" }
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Origin is not allowed")
    expect(Question.count).to eq(0)

    options "/api/admin/questions/1", headers: {
      "Origin" => "http://localhost:3000",
      "Access-Control-Request-Method" => "PUT"
    }
    expect(response.headers.fetch("Access-Control-Allow-Methods")).to include("PUT", "PATCH")
  end

  it "initializes and updates bounded confidence multipliers" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    get "/api/admin/confidence-multipliers"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("high" => "2.00", "normal" => "1.00", "low" => "0.50")

    patch "/api/admin/confidence-multipliers/high", params: { confidenceMultiplier: 9.99 }, as: :json, headers: { "Origin" => "https://attacker.example" }
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Origin is not allowed")

    patch "/api/admin/confidence-multipliers/high", params: { confidenceMultiplier: 9.99 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("high" => "9.99", "normal" => "1.00", "low" => "0.50")

    patch "/api/admin/confidence-multipliers/low", params: { confidenceMultiplier: 0 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("low")).to eq("0.00")

    patch "/api/admin/confidence-multipliers/high", params: { confidenceMultiplier: 10 }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include("error")

    patch "/api/admin/confidence-multipliers/high", params: { confidenceMultiplier: 1.234 }, as: :json
    expect(response).to have_http_status(:unprocessable_content)

    patch "/api/admin/confidence-multipliers/unknown", params: { confidenceMultiplier: 1 }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to eq("level must be high, normal, or low")
  end

  private

  def post_question(payload)
    post "/api/admin/questions", params: payload, as: :json
  end

  def question_payload(
    question_text: "Question",
    choice_a: "選択肢A",
    choice_b: "選択肢B",
    choice_c: "選択肢C",
    choice_d: "選択肢D",
    correct_answer: "A",
    image_url: nil
  )
    {
      questionText: question_text,
      choiceA: choice_a,
      choiceB: choice_b,
      choiceC: choice_c,
      choiceD: choice_d,
      correctAnswer: correct_answer,
      imageUrl: image_url
    }
  end

  def question_attributes(position:)
    {
      position:, question_text: "Question", choice_a: "選択肢A", choice_b: "選択肢B",
      choice_c: "選択肢C", choice_d: "選択肢D", correct_answer: "A"
    }
  end

  def same_origin_headers
    { "Origin" => "http://localhost:3000" }
  end

  def authenticate_as(session)
    [ AdminAuth::DEVICE_COOKIE, AdminAuth::SESSION_COOKIE, AdminAuth::APPLICANT_SESSION_COOKIE ].each { |name| cookies.delete(name) }
    cookies[AdminAuth::DEVICE_COOKIE] = session.device
    cookies[session.cookie_name] = session.session_key
  end

  def build_session(source, admin_enabled: false)
    suffix = SecureRandom.uuid
    identity = AdminIdentity.create!(
      email: "#{source.downcase}-#{suffix}@example.com",
      google_sub: "sub-#{suffix}",
      admin_enabled:
    )
    device = SecureRandom.urlsafe_base64(32, false)
    session_key = SecureRandom.urlsafe_base64(32, false)
    AdminDeviceSession.create!(
      admin_identity: identity,
      device_id_hash: Digest::SHA256.digest(device),
      session_key_hash: Digest::SHA256.digest(session_key),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: source,
      expires_at: 1.hour.from_now,
      last_seen_at: Time.current
    )
    cookie_name = source == "APPLICANT" ? AdminAuth::APPLICANT_SESSION_COOKIE : AdminAuth::SESSION_COOKIE
    QuestionManagementSessionFixture.new(identity, device, session_key, cookie_name)
  end
end
