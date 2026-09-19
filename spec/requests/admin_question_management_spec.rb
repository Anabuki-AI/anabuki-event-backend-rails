require "rails_helper"
require "aws-sdk-s3"

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
    get "/api/admin/questions/1/image"
    expect(response).to have_http_status(:unauthorized)

    authenticate_as(build_session("APPLICANT"))
    get "/api/admin/questions"
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Management page access is required")
    get "/api/admin/questions/1/image"
    expect(response).to have_http_status(:forbidden)
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
    expect(response.parsed_body.map { |question| question.fetch("position") }).to eq([ 1 ])
  end

  it "uploads, serves, and removes a question image alongside explanation and target audience text" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post "/api/admin/questions", params: question_payload.merge(
      explanation: "これは解説です",
      targetAudience: "初級者向け",
      image: fixture_file_upload("question.webp", "image/webp")
    )
    expect(response).to have_http_status(:created)
    created = response.parsed_body
    expect(created).to include("explanation" => "これは解説です", "targetAudience" => "初級者向け")
    expect(created.fetch("imageUrl")).to eq("/admin/questions/#{created.fetch('id')}/image")

    get "/api#{created.fetch('imageUrl')}"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/webp")

    put "/api/admin/questions/#{created.fetch('id')}", params: question_payload.merge(removeImage: "true")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("imageUrl")).to be_nil

    get "/api/admin/questions/#{created.fetch('id')}/image"
    expect(response).to have_http_status(:not_found)
  end

  it "preserves the original attachment and bytes on invalid removal or replacement" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    post "/api/admin/questions", params: question_payload.merge(image: fixture_file_upload("question.webp", "image/webp"))
    question = Question.find(response.parsed_body.fetch("id"))
    blob = question.image.blob
    bytes = blob.download

    [ { removeImage: "true" }, { image: fixture_file_upload("notes.txt", "text/plain") },
      { image: fixture_file_upload("question.webp", "image/webp") } ].each do |image_change|
      put "/api/admin/questions/#{question.id}", params: question_payload(question_text: " ").merge(image_change)
      expect(response).to have_http_status(:unprocessable_content)
      expect(question.reload.image.blob.id).to eq(blob.id)
      expect(blob.download).to eq(bytes)
      get "/api/admin/questions/#{question.id}/image"
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(bytes)
    end
  end

  it "replaces an image only after a successful update" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    post "/api/admin/questions", params: question_payload.merge(image: fixture_file_upload("question.webp", "image/webp"))
    question = Question.find(response.parsed_body.fetch("id"))
    old_blob_id = question.image.blob.id

    put "/api/admin/questions/#{question.id}", params: question_payload.merge(image: fixture_file_upload("question.webp", "image/webp"))
    expect(response).to have_http_status(:ok)
    expect(question.reload.image.blob.id).not_to eq(old_blob_id)
    get "/api/admin/questions/#{question.id}/image"
    expect(response).to have_http_status(:ok)
  end

  context "when the object storage upload fails" do
    before { authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true)) }

    def stub_upload_failure(error)
      allow_any_instance_of(ActiveStorage::Blob).to receive(:upload_without_unfurling).and_raise(error)
    end

    it "returns 502 JSON and leaves the question untouched on update" do
      post "/api/admin/questions", params: question_payload(question_text: "before")
      question = Question.find(response.parsed_body.fetch("id"))
      stub_upload_failure(Aws::S3::Errors::InternalError.new(nil, "r2 boom"))
      allow(Rails.logger).to receive(:error).and_call_original

      put "/api/admin/questions/#{question.id}", params: question_payload(question_text: "after").merge(image: fixture_file_upload("question.webp", "image/webp"))

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body.fetch("error")).to include("画像の保存に失敗")
      expect(Rails.logger).to have_received(:error).with(/Aws::S3::Errors::InternalError: r2 boom/)
      expect(question.reload.question_text).to eq("before")
      expect(question.image).not_to be_attached
      expect(ActiveStorage::Attachment.count).to eq(0)
    end

    it "returns 502 JSON for network errors and creates no question on create" do
      stub_upload_failure(Seahorse::Client::NetworkingError.new(StandardError.new("timeout"), "timeout"))

      expect {
        post "/api/admin/questions", params: question_payload.merge(image: fixture_file_upload("question.webp", "image/webp"))
      }.not_to change(Question, :count)

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to have_key("error")
    end
  end

  it "rejects deleting the current question before it receives any answers" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    question = Question.create!(question_attributes(position: 1))
    QuizSession.current.start!

    delete "/api/admin/questions/#{question.id}"

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("fieldErrors")).to include("base")
    expect(QuizSession.current.current_question_id).to eq(question.id)
    expect(Question.exists?(question.id)).to be(true)
    expect(AuditLog.where(event_type: "QUESTION_DELETED")).not_to exist
  end

  it "retains answered questions, scores and rankings after finish instead of cascading deletion" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    ConfidenceMultiplier.all_levels
    question = Question.create!(question_attributes(position: 1))
    answer = create_participant_answer(question:, choice: "A", confidence_level: "high")
    QuizSession.current.start!
    QuizSession.current.reveal!
    QuizSession.current.finish!
    get "/api/rankings"
    rankings = response.parsed_body
    expect(rankings.fetch("rankings")).not_to be_empty

    delete "/api/admin/questions/#{question.id}"

    expect(response).to have_http_status(:unprocessable_content)
    expect(answer.reload.awarded_points).to eq(200)
    expect(Question.exists?(question.id)).to be(true)
    get "/api/rankings"
    expect(response.parsed_body).to eq(rankings)
  end

  it "renumbers remaining questions to 1..n after deleting the first, a middle, and the last question" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    questions = (1..5).map { |n| Question.create!(question_attributes(position: n).merge(question_text: "Q#{n}")) }

    delete "/api/admin/questions/#{questions[0].id}", headers: same_origin_headers
    expect(response).to have_http_status(:no_content)
    expect(Question.order(:position).pluck(:question_text, :position)).to eq([ [ "Q2", 1 ], [ "Q3", 2 ], [ "Q4", 3 ], [ "Q5", 4 ] ])

    delete "/api/admin/questions/#{questions[2].id}", headers: same_origin_headers
    expect(Question.order(:position).pluck(:question_text, :position)).to eq([ [ "Q2", 1 ], [ "Q4", 2 ], [ "Q5", 3 ] ])

    delete "/api/admin/questions/#{questions[4].id}", headers: same_origin_headers
    expect(Question.order(:position).pluck(:question_text, :position)).to eq([ [ "Q2", 1 ], [ "Q4", 2 ] ])
  end

  it "does not renumber when deleting a used question is rejected" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    used = Question.create!(question_attributes(position: 1).merge(question_text: "used"))
    Question.create!(question_attributes(position: 2).merge(question_text: "next"))
    used.update_columns(revealed_at: Time.current)

    delete "/api/admin/questions/#{used.id}", headers: same_origin_headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(Question.order(:position).pluck(:question_text, :position)).to eq([ [ "used", 1 ], [ "next", 2 ] ])
  end

  it "retains a past question with a confidence selection even without an answer" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    question = Question.create!(question_attributes(position: 1))
    participant = Participant.create!(display_name: "Player", gender: "no_answer", age_group: "20s", student_type: "not_student", agreed_terms: true)
    session = QuizSession.current
    session.start!
    selection = session.select_confidence_level!(participant:, question_id: question.id, confidence_level: "low")
    session.finish!

    delete "/api/admin/questions/#{question.id}"

    expect(response).to have_http_status(:unprocessable_content)
    expect(ParticipantQuizConfidenceSelection.exists?(selection.id)).to be(true)
  end

  it "rejects live answer and choice edits, keeping Lv.1 elimination, answers and displayed choices consistent" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    ConfidenceMultiplier.all_levels
    question = Question.create!(question_attributes(position: 1))
    participant = Participant.create!(display_name: "Player", gender: "no_answer", age_group: "20s", student_type: "not_student", agreed_terms: true)
    session = QuizSession.current
    session.start!
    selection = session.select_confidence_level!(participant:, question_id: question.id, confidence_level: "low")
    answer = session.record_answer!(participant:, question_id: question.id, choice: "A")

    put "/api/admin/questions/#{question.id}", params: question_payload(correct_answer: selection.eliminated_choice, choice_a: "Changed"), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("fieldErrors")).to include("correctAnswer", "choiceA")
    expect(question.reload.correct_answer).to eq("A")
    expect(answer.reload).to have_attributes(choice: "A", awarded_points: 50)
    token = SecureRandom.urlsafe_base64(32, false)
    ParticipantSession.create!(participant:, token_hash: Digest::SHA256.digest(token), expires_at: 1.hour.from_now)
    cookies["participant_session"] = token
    get "/api/participant/quiz/state"
    expect(response.parsed_body.dig("question", "choices")).to include("A" => "選択肢A")
    expect(response.parsed_body.dig("question", "eliminated_choice")).to eq(selection.eliminated_choice)
    expect(response.parsed_body.dig("my_answer", "choice")).to eq("A")
    expect(selection.reload.eliminated_choice).not_to eq(question.correct_answer)
  end

  it "rejects live image removal without losing its blob" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    post "/api/admin/questions", params: question_payload.merge(image: fixture_file_upload("question.webp", "image/webp"))
    question = Question.find(response.parsed_body.fetch("id"))
    blob = question.image.blob
    QuizSession.current.start!

    put "/api/admin/questions/#{question.id}", params: question_payload.merge(removeImage: "true")

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("fieldErrors")).to include("image")
    expect(question.reload.image.blob.id).to eq(blob.id)
    expect(blob.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/question.webp")))
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

  it "recalculates only the edited question's scores after the quiz has finished" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    ConfidenceMultiplier.all_levels
    question = Question.create!(question_attributes(position: 1).merge(points: 100))
    other_question = Question.create!(question_attributes(position: 2).merge(points: 100))
    correct_before_edit = create_participant_answer(question:, choice: "A", confidence_level: "high")
    correct_after_edit = create_participant_answer(question:, choice: "B", confidence_level: "low")
    unaffected_choice = create_participant_answer(question:, choice: "C", confidence_level: "normal")
    unrelated_answer = create_participant_answer(question: other_question, choice: "A", confidence_level: "normal")
    unaffected_updated_at = unaffected_choice.updated_at
    unrelated_updated_at = unrelated_answer.updated_at
    QuizSession.current.update!(status: "finished")

    put "/api/admin/questions/#{question.id}", params: question_payload(correct_answer: "B").merge(points: 240), as: :json

    expect(response).to have_http_status(:ok)
    expect(correct_before_edit.reload.awarded_points).to eq(-120)
    expect(correct_after_edit.reload.awarded_points).to eq(120)
    expect(unaffected_choice.reload).to have_attributes(awarded_points: 0, updated_at: unaffected_updated_at)
    expect(unrelated_answer.reload).to have_attributes(awarded_points: 100, updated_at: unrelated_updated_at)
  end

  it "does not rewrite answer scores when only non-scoring question fields change" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))
    ConfidenceMultiplier.all_levels
    question = Question.create!(question_attributes(position: 1))
    answer = create_participant_answer(question:, choice: "A", confidence_level: "normal")
    answer_updated_at = answer.updated_at

    put "/api/admin/questions/#{question.id}", params: question_payload(question_text: "Updated text"), as: :json

    expect(response).to have_http_status(:ok)
    expect(answer.reload).to have_attributes(awarded_points: 100, updated_at: answer_updated_at)
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

  it "locks correctAnswer for an unselected relay question and unlocks it once selected" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post_question(question_payload.merge(isRelayQuestion: true))
    expect(response).to have_http_status(:created)
    relay = response.parsed_body
    expect(relay).to include("isRelayQuestion" => true, "isSelectedRelayQuestion" => false, "correctAnswer" => "A")

    put "/api/admin/questions/#{relay.fetch('id')}", params: question_payload(correct_answer: "B").merge(isRelayQuestion: true), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("fieldErrors")).to include("correctAnswer")
    get "/api/admin/questions/#{relay.fetch('id')}"
    expect(response.parsed_body.fetch("correctAnswer")).to eq("A")

    put "/api/admin/questions/#{relay.fetch('id')}", params: question_payload.merge(isRelayQuestion: true, isSelectedRelayQuestion: true), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("isSelectedRelayQuestion" => true)

    put "/api/admin/questions/#{relay.fetch('id')}", params: question_payload(correct_answer: "B").merge(isRelayQuestion: true, isSelectedRelayQuestion: true), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("correctAnswer" => "B")
  end

  it "keeps correctAnswer editable for a relay question already revealed live, even after it is deselected" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post_question(question_payload.merge(isRelayQuestion: true))
    first = response.parsed_body
    expect(first).to include("revealedAt" => nil)
    post_question(question_payload(question_text: "2問目").merge(isRelayQuestion: true))
    second = response.parsed_body

    put "/api/admin/questions/#{first.fetch('id')}", params: question_payload.merge(isRelayQuestion: true, isSelectedRelayQuestion: true), as: :json
    expect(response).to have_http_status(:ok)

    # Simulate the live progression having already revealed this question's
    # answer (QuizSession#reveal! sets this outside the admin API).
    Question.find(first.fetch("id")).update!(revealed_at: Time.current)

    # Selecting the second relay question deselects the first one.
    put "/api/admin/questions/#{second.fetch('id')}", params: question_payload(question_text: "2問目").merge(isRelayQuestion: true, isSelectedRelayQuestion: true), as: :json
    expect(response).to have_http_status(:ok)
    get "/api/admin/questions/#{first.fetch('id')}"
    expect(response.parsed_body).to include("isSelectedRelayQuestion" => false)
    expect(response.parsed_body.fetch("revealedAt")).to be_present

    put "/api/admin/questions/#{first.fetch('id')}", params: question_payload(correct_answer: "B").merge(isRelayQuestion: true), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("correctAnswer" => "B")
  end

  it "selects at most one relay question at a time, deselecting the previous selection" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post_question(question_payload.merge(isRelayQuestion: true))
    first = response.parsed_body
    post_question(question_payload(question_text: "2問目").merge(isRelayQuestion: true))
    second = response.parsed_body

    put "/api/admin/questions/#{first.fetch('id')}", params: question_payload.merge(isRelayQuestion: true, isSelectedRelayQuestion: true), as: :json
    expect(response.parsed_body).to include("isSelectedRelayQuestion" => true)

    put "/api/admin/questions/#{second.fetch('id')}", params: question_payload(question_text: "2問目").merge(isRelayQuestion: true, isSelectedRelayQuestion: true), as: :json
    expect(response.parsed_body).to include("isSelectedRelayQuestion" => true)

    get "/api/admin/questions/#{first.fetch('id')}"
    expect(response.parsed_body).to include("isSelectedRelayQuestion" => false)
  end

  it "reports isLiveQuestion for the question currently on the progression screen, independent of relay selection" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post_question(question_payload.merge(isRelayQuestion: true))
    relay = response.parsed_body
    post_question(question_payload(question_text: "2問目"))
    other = response.parsed_body

    get "/api/admin/questions"
    expect(response.parsed_body.map { |q| q.fetch("isLiveQuestion") }).to eq([ false, false ])

    put "/api/admin/questions/#{relay.fetch('id')}", params: question_payload.merge(isRelayQuestion: true, isSelectedRelayQuestion: true), as: :json
    expect(response.parsed_body).to include("isSelectedRelayQuestion" => true, "isLiveQuestion" => false)

    # Selecting a relay question as "this round's question" never touches
    # quiz_sessions -- it must not be reported as live by itself.
    get "/api/admin/questions/#{relay.fetch('id')}"
    expect(response.parsed_body).to include("isLiveQuestion" => false)

    QuizSession.current.start!
    get "/api/admin/questions/#{relay.fetch('id')}"
    expect(response.parsed_body).to include("isLiveQuestion" => true)
    get "/api/admin/questions/#{other.fetch('id')}"
    expect(response.parsed_body).to include("isLiveQuestion" => false)

    QuizSession.current.reveal!
    get "/api/admin/questions/#{relay.fetch('id')}"
    expect(response.parsed_body).to include("isLiveQuestion" => true)
    expect(response.parsed_body.fetch("revealedAt")).to be_present

    QuizSession.current.publish_next!
    get "/api/admin/questions/#{relay.fetch('id')}"
    expect(response.parsed_body).to include("isLiveQuestion" => false)
    get "/api/admin/questions/#{other.fetch('id')}"
    expect(response.parsed_body).to include("isLiveQuestion" => true)
  end

  it "does not restrict correctAnswer changes for a non-relay question" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post_question(question_payload)
    question = response.parsed_body

    put "/api/admin/questions/#{question.fetch('id')}", params: question_payload(correct_answer: "B"), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("correctAnswer" => "B")
  end

  it "does not carry a non-relay answer into a relay question when editing" do
    authenticate_as(build_session("MANAGEMENT_ACCESS", admin_enabled: true))

    post_question(question_payload(correct_answer: "C"))
    question = response.parsed_body

    put "/api/admin/questions/#{question.fetch('id')}",
      params: question_payload(correct_answer: "C").merge(isRelayQuestion: true),
      as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "isRelayQuestion" => true,
      "isSelectedRelayQuestion" => false,
      "correctAnswer" => Question::RELAY_QUESTION_DEFAULT_CORRECT_ANSWER
    )
    expect(Question.find(question.fetch("id")).correct_answer).to eq(Question::RELAY_QUESTION_DEFAULT_CORRECT_ANSWER)
  end

  private

  describe "POST /api/admin/questions/bulk_destroy" do
    let(:operator) { build_session("MANAGEMENT_ACCESS", admin_enabled: true) }

    def bulk_destroy(ids)
      post "/api/admin/questions/bulk_destroy", params: { ids: }, as: :json, headers: same_origin_headers
    end

    def create_questions(count)
      (1..count).map { |n| Question.create!(question_attributes(position: n).merge(question_text: "Q#{n}")) }
    end

    it "requires authentication and operator access" do
      bulk_destroy([ 1 ])
      expect(response).to have_http_status(:unauthorized)

      authenticate_as(build_session("APPLICANT"))
      bulk_destroy([ 1 ])
      expect(response).to have_http_status(:forbidden)
    end

    it "deletes the selected questions, renumbers the rest and writes one audit log per question" do
      authenticate_as(operator)
      questions = create_questions(5)

      bulk_destroy([ questions[0].id, questions[2].id, questions[4].id ])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("deletedCount" => 3, "deletedIds" => [ questions[0].id, questions[2].id, questions[4].id ])
      expect(Question.order(:position).pluck(:question_text, :position)).to eq([ [ "Q2", 1 ], [ "Q4", 2 ] ])
      logs = AuditLog.where(event_type: "QUESTION_DELETED")
      expect(logs.pluck(:target_id)).to match_array(questions.values_at(0, 2, 4).map { |q| q.id.to_s })
      expect(logs.first.detail).to eq("bulk" => true)
    end

    it "deletes revealed, answered and live questions with their answers and confidence selections" do
      authenticate_as(operator)
      ConfidenceMultiplier.all_levels
      questions = create_questions(3)
      participant = Participant.create!(display_name: "Player", gender: "no_answer", age_group: "20s", student_type: "not_student", agreed_terms: true)
      session = QuizSession.current
      session.start!
      answer = create_participant_answer(question: questions[0], choice: "A", confidence_level: "high")
      session.reveal!
      session.publish_next!
      selection = session.select_confidence_level!(participant:, question_id: questions[1].id, confidence_level: "low")
      expect(session.reload.current_question_id).to eq(questions[1].id)

      bulk_destroy(questions.map(&:id))

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("deletedCount")).to eq(3)
      expect(Question.count).to eq(0)
      expect(ParticipantAnswer.exists?(answer.id)).to be(false)
      expect(ParticipantQuizConfidenceSelection.exists?(selection.id)).to be(false)
    end

    it "puts the session back to waiting when the live question is deleted, leaving other questions intact" do
      authenticate_as(operator)
      questions = create_questions(3)
      QuizSession.current.start!

      bulk_destroy([ questions[0].id ])

      expect(response).to have_http_status(:ok)
      session = QuizSession.current
      expect([ session.status, session.current_question_id, session.phase ]).to eq([ "waiting", nil, nil ])
      expect(Question.order(:position).pluck(:question_text, :position)).to eq([ [ "Q2", 1 ], [ "Q3", 2 ] ])
    end

    it "keeps the live session untouched when the live question is not selected" do
      authenticate_as(operator)
      questions = create_questions(3)
      QuizSession.current.start!

      bulk_destroy([ questions[2].id ])

      expect(response).to have_http_status(:ok)
      session = QuizSession.current
      expect([ session.status, session.current_question_id ]).to eq([ "in_progress", questions[0].id ])
    end

    it "is all-or-nothing: unknown ids return 404 and delete nothing" do
      authenticate_as(operator)
      questions = create_questions(2)

      bulk_destroy([ questions[0].id, 999_999 ])

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to include("missingIds" => [ 999_999 ])
      expect(Question.count).to eq(2)
      expect(AuditLog.where(event_type: "QUESTION_DELETED")).not_to exist
    end

    it "rejects missing, empty and malformed ids" do
      authenticate_as(operator)
      create_questions(1)

      [ nil, [], "1", [ "abc" ], [ 1, { a: 1 } ] ].each do |ids|
        bulk_destroy(ids)
        expect(response).to have_http_status(:unprocessable_content)
      end
      expect(Question.count).to eq(1)
    end

    it "accepts duplicate ids and numeric strings" do
      authenticate_as(operator)
      questions = create_questions(2)

      bulk_destroy([ questions[0].id, questions[0].id.to_s ])

      expect(response.parsed_body.fetch("deletedCount")).to eq(1)
    end

    it "does not change single-delete protection for used questions" do
      authenticate_as(operator)
      questions = create_questions(2)
      QuizSession.current.start!

      delete "/api/admin/questions/#{questions[0].id}", headers: same_origin_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(Question.exists?(questions[0].id)).to be(true)
    end

    it "exposes hasParticipantData on the question list" do
      authenticate_as(operator)
      ConfidenceMultiplier.all_levels
      questions = create_questions(2)
      create_participant_answer(question: questions[0], choice: "A", confidence_level: "high")

      get "/api/admin/questions"

      expect(response.parsed_body.map { |q| q.fetch("hasParticipantData") }).to eq([ true, false ])
    end
  end

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

  def create_participant_answer(question:, choice:, confidence_level:)
    participant = Participant.create!(
      display_name: "Player #{SecureRandom.hex(4)}",
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
    ParticipantAnswer.record!(participant:, question:, choice:, confidence_level:)
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
