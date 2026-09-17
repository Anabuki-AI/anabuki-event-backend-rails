require "rails_helper"

RSpec.describe "Rankings and voting rate", type: :request do
  around do |example|
    with_env("PUBLIC_BASE_URL" => "https://event.example") do
      host! "event.example"
      https!
      example.run
    end
  end

  let(:multiplier_low) do
    ConfidenceMultiplier.all_levels
    ConfidenceMultiplier.find_by!(level: "low")
  end

  let!(:question1) { create_question(position: 1) }
  let!(:question2) { create_question(position: 2) }

  # Operator tables live in a separate database, which transactional fixtures
  # do not roll back; clean them before every example.
  before do
    Operator::DeviceSession.delete_all
    Operator::Identity.delete_all
  end

  def create_question(position:)
    Question.create!(
      position:,
      question_text: "Question #{position}",
      choice_a: "choice A",
      choice_b: "choice B",
      choice_c: "choice C",
      choice_d: "choice D",
      correct_answer: "B"
    )
  end

  def create_participant(display_name)
    Participant.create!(
      display_name:,
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
  end

  def reveal_all_questions
    session = QuizSession.current
    session.start!
    loop do
      session.reveal!
      break unless session.next_question

      session.publish_next!
    end
  end

  def create_participant_session(participant)
    raw_token = SecureRandom.urlsafe_base64(32, false)
    ParticipantSession.create!(
      participant:,
      token_hash: Digest::SHA256.digest(raw_token),
      expires_at: 1.hour.from_now
    )
    raw_token
  end

  def sign_in(participant)
    cookies["participant_session"] = create_participant_session(participant)
  end

  def answer(participant, question, choice:, level: "low", points: nil)
    multiplier = multiplier_low
    expected = points || (choice == question.correct_answer ? (ParticipantAnswer::BASE_SCORE * multiplier.confidence_multiplier).round : 0)
    ParticipantAnswer.create!(
      participant:,
      question:,
      choice:,
      confidence_level: level,
      awarded_points: expected
    )
  end

  describe "GET /api/rankings" do
    it "requires either a participant session or an event operator session" do
      get "/api/rankings"
      expect(response).to have_http_status(:unauthorized)

      Operator::Identity.create!(email: "operator-applicant@example.com", google_sub: "sub-applicant", manager_enabled: false)
      device = SecureRandom.urlsafe_base64(32, false)
      session_key = SecureRandom.urlsafe_base64(32, false)
      Operator::DeviceSession.create!(
        operator_identity: Operator::Identity.sole,
        device_id_hash: Digest::SHA256.digest(device),
        session_key_hash: Digest::SHA256.digest(session_key),
        email: "operator-applicant@example.com",
        google_sub: "sub-applicant",
        access_source: "APPLICANT",
        expires_at: 1.hour.from_now,
        last_seen_at: Time.current
      )
      cookies[OperatorAuth::APPLICANT_SESSION_COOKIE] = session_key

      get "/api/rankings"
      expect(response).to have_http_status(:unauthorized)
    end

    it "ranks participants by total awarded points in descending order" do
      alice = create_participant("Alice")
      bob = create_participant("Bob")
      carol = create_participant("Carol")

      answer(alice, question1, choice: "B", points: 200) # correct
      answer(bob, question1, choice: "A", points: 0)     # wrong
      answer(carol, question1, choice: "B", points: 150)
      answer(carol, question2, choice: "B", points: 100)
      reveal_all_questions

      sign_in(alice)
      get "/api/rankings"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["rankings"]).to eq([
        { "rank" => 1, "participant_id" => carol.id, "display_name" => "Carol" },
        { "rank" => 2, "participant_id" => alice.id, "display_name" => "Alice" },
        { "rank" => 3, "participant_id" => bob.id, "display_name" => "Bob" }
      ])
      expect(body["me"]).to eq({ "rank" => 2, "participant_id" => alice.id, "display_name" => "Alice" })
    end

    it "assigns the same rank to equal scores and skips the next rank" do
      alice = create_participant("Alice")
      bob = create_participant("Bob")
      carol = create_participant("Carol")

      answer(alice, question1, choice: "B", points: 200)
      answer(bob, question1, choice: "A", points: 200)
      answer(carol, question1, choice: "A", points: 50)
      reveal_all_questions

      sign_in(carol)
      get "/api/rankings"

      expect(response.parsed_body["rankings"].map { |r| r["rank"] }).to eq([ 1, 1, 3 ])
      expect(response.parsed_body["me"]["rank"]).to eq(3)
    end

    it "returns the top 20 participants plus me beyond the cutoff" do
      25.times do |index|
        participant = create_participant("Player #{index}")
        answer(participant, question1, choice: "B", points: 100 - index)
      end
      me = create_participant("Me")
      answer(me, question1, choice: "B", points: 10)
      reveal_all_questions

      sign_in(me)
      get "/api/rankings"

      rankings = response.parsed_body["rankings"]
      expect(rankings.size).to eq(20)
      expect(rankings.last["display_name"]).to eq("Player 19")
      expect(response.parsed_body["me"]).to include("display_name" => "Me", "rank" => 26)
    end

    it "excludes answers for questions whose correct answer is not revealed" do
      alice = create_participant("Alice")
      answer(alice, question1, choice: "B", points: 200)
      answer(alice, question2, choice: "B", points: 500)
      QuizSession.current.start!
      QuizSession.current.reveal!

      sign_in(alice)
      get "/api/rankings"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["rankings"]).to eq([
        { "rank" => 1, "participant_id" => alice.id, "display_name" => "Alice" }
      ])
      expect(question1.reload.revealed_at).to be_present
      expect(question2.reload.revealed_at).to be_nil
    end

    it "returns empty rankings and null me when nobody answered" do
      participant = create_participant("Alice")
      sign_in(participant)

      get "/api/rankings"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("rankings" => [], "me" => nil)
    end

    it "allows an operator manager session to read the rankings" do
      Operator::Identity.create!(email: "manager@example.com", google_sub: "sub-manager", manager_enabled: true)
      device = SecureRandom.urlsafe_base64(32, false)
      session_key = SecureRandom.urlsafe_base64(32, false)
      Operator::DeviceSession.create!(
        operator_identity: Operator::Identity.sole,
        device_id_hash: Digest::SHA256.digest(device),
        session_key_hash: Digest::SHA256.digest(session_key),
        email: "manager@example.com",
        google_sub: "sub-manager",
        access_source: "MANAGER",
        expires_at: 1.hour.from_now,
        last_seen_at: Time.current
      )
      cookies[OperatorAuth::DEVICE_COOKIE] = device
      cookies[OperatorAuth::SESSION_COOKIE] = session_key

      get "/api/rankings"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["rankings"]).to eq([])
      expect(response.parsed_body["me"]).to be_nil
    end
  end

  describe "GET /api/operator/voting-rate" do
    it "requires an event operator session" do
      get "/api/operator/voting-rate"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns answered_count and answered_rate for every question" do
      alice = create_participant("Alice")
      bob = create_participant("Bob")
      carol = create_participant("Carol")
      answer(alice, question1, choice: "B", points: 200)
      answer(bob, question1, choice: "A", points: 0)

      Operator::Identity.create!(email: "manager@example.com", google_sub: "sub-manager", manager_enabled: true)
      device = SecureRandom.urlsafe_base64(32, false)
      session_key = SecureRandom.urlsafe_base64(32, false)
      Operator::DeviceSession.create!(
        operator_identity: Operator::Identity.sole,
        device_id_hash: Digest::SHA256.digest(device),
        session_key_hash: Digest::SHA256.digest(session_key),
        email: "manager@example.com",
        google_sub: "sub-manager",
        access_source: "MANAGER",
        expires_at: 1.hour.from_now,
        last_seen_at: Time.current
      )
      cookies[OperatorAuth::DEVICE_COOKIE] = device
      cookies[OperatorAuth::SESSION_COOKIE] = session_key

      get "/api/operator/voting-rate"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["total_participants"]).to eq(3)
      expect(body["questions"]).to eq([
        { "question_id" => question1.id, "position" => 1, "answered_count" => 2, "answered_rate" => 0.67 },
        { "question_id" => question2.id, "position" => 2, "answered_count" => 0, "answered_rate" => 0.0 }
      ])
    end
  end
end
