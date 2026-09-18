require "rails_helper"

RSpec.describe "Production tournament reset", type: :request do
  around do |example|
    with_env(
      "PUBLIC_BASE_URL" => "https://event.example",
      "ADMIN_FRONTEND_URL" => "https://event.example/admin",
      "OPERATOR_FRONTEND_URL" => "https://event.example/operator"
    ) do
      host! "event.example"
      https!
      example.run
    end
  end

  let(:headers) { { "Origin" => "https://event.example" } }
  let(:reset_params) { { confirmation: "RESET" } }

  describe "authorization" do
    it "rejects anonymous and applicant operator sessions" do
      post "/api/operator/quiz/reset", params: reset_params, headers:, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(AuditLog.where(event_type: TournamentReset::EVENT_TYPE)).to be_empty

      authenticate_operator(manager_enabled: false)
      post "/api/operator/quiz/reset", params: reset_params, headers:, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(AuditLog.where(event_type: TournamentReset::EVENT_TYPE)).to be_empty
    end

    it "allows an operator manager under the existing event-operator policy" do
      authenticate_operator(manager_enabled: true)

      post "/api/operator/quiz/reset", params: reset_params, headers:, as: :json

      expect(response).to have_http_status(:ok)
      expect(AuditLog.where(event_type: TournamentReset::EVENT_TYPE).count).to eq(1)
    end

    it "allows an admin management session under the existing event-operator policy" do
      actor = authenticate_admin

      post "/api/operator/quiz/reset", params: reset_params, headers:, as: :json

      expect(response).to have_http_status(:ok)
      entry = AuditLog.find_by!(event_type: TournamentReset::EVENT_TYPE)
      expect(entry).to have_attributes(
        admin_identity_id: actor.id,
        actor_email: actor.email,
        actor_google_sub: actor.google_sub
      )
    end

    it "attributes a mixed admin-applicant/operator-manager request to the authorizing operator" do
      admin_applicant = authenticate_admin(access_source: "APPLICANT")
      operator_manager = authenticate_operator(manager_enabled: true)

      post "/api/operator/quiz/reset", params: reset_params, headers:, as: :json

      expect(response).to have_http_status(:ok)
      entry = AuditLog.find_by!(event_type: TournamentReset::EVENT_TYPE)
      expect(entry).to have_attributes(
        admin_identity_id: nil,
        actor_email: operator_manager.email,
        actor_google_sub: operator_manager.google_sub
      )
      expect(entry.actor_email).not_to eq(admin_applicant.email)
    end
  end

  it "treats missing or cancelled confirmation as no-op requests" do
    authenticate_operator(manager_enabled: true)
    fixture = create_full_tournament
    before_state = tournament_snapshot(fixture)

    [ {}, { confirmation: "CANCEL" }, { confirmation: "reset" } ].each do |params|
      post "/api/operator/quiz/reset", params:, headers:, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq("error" => "confirmation must exactly equal RESET")
      expect(tournament_snapshot(fixture)).to eq(before_state)
    end

    expect(AuditLog.where(event_type: TournamentReset::EVENT_TYPE)).to be_empty
  end

  it "atomically purges participant data, resets live state, preserves configuration/staff/history, and audits exact counts" do
    actor = authenticate_operator(manager_enabled: true)
    fixture = create_full_tournament
    preserved_audit = AuditLog.create!(event_type: "ADMIN_LOGGED_OUT", occurred_at: 1.minute.ago)
    question_snapshot = Question.order(:id).pluck(
      :id, :position, :question_text, :choice_a, :choice_b, :choice_c, :choice_d, :correct_answer,
      :points, :time_limit_seconds, :is_relay_question, :is_selected_relay_question
    )
    multiplier_snapshot = ConfidenceMultiplier.order(:level).pluck(:level, :confidence_multiplier)
    staff_snapshot = [ AdminIdentity.order(:id).pluck(:id), Operator::Identity.order(:id).pluck(:id) ]

    post "/api/operator/quiz/reset", params: reset_params, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(Participant).to be_none
    expect(ParticipantSession).to be_none
    expect(ParticipantReaction).to be_none
    expect(ParticipantAnswer).to be_none
    expect(ParticipantQuizConfidenceSelection).to be_none
    expect(Question.where.not(revealed_at: nil)).to be_none
    expect(QuizSession.current.reload).to have_attributes(
      status: "waiting",
      current_question_id: nil,
      phase: nil,
      phase_started_at: nil,
      answering_started_at: nil,
      finished_elapsed_seconds: nil
    )

    expect(Question.order(:id).pluck(
      :id, :position, :question_text, :choice_a, :choice_b, :choice_c, :choice_d, :correct_answer,
      :points, :time_limit_seconds, :is_relay_question, :is_selected_relay_question
    )).to eq(question_snapshot)
    expect(ConfidenceMultiplier.order(:level).pluck(:level, :confidence_multiplier)).to eq(multiplier_snapshot)
    expect([ AdminIdentity.order(:id).pluck(:id), Operator::Identity.order(:id).pluck(:id) ]).to eq(staff_snapshot)
    expect(AuditLog.exists?(preserved_audit.id)).to be(true)

    expected_rows = {
      "participants" => 2,
      "participant_sessions" => 2,
      "participant_reactions" => 1,
      "participant_answers" => 1,
      "confidence_selections" => 1,
      "question_reveals" => 1,
      "quiz_sessions" => 1
    }
    body = response.parsed_body
    expect(body.slice("status", "phase", "current", "total_participants")).to eq(
      "status" => "waiting", "phase" => nil, "current" => nil, "total_participants" => 0
    )
    expect(body.dig("reset_operation", "affected_rows")).to eq(expected_rows)

    entry = AuditLog.find_by!(event_type: TournamentReset::EVENT_TYPE)
    expect(entry).to have_attributes(
      admin_identity_id: nil,
      actor_email: actor.email,
      actor_google_sub: actor.google_sub,
      target_type: "TOURNAMENT",
      target_id: entry.operation_id
    )
    expect(entry.operation_id).to eq(body.dig("reset_operation", "operation_id"))
    expect(entry.operation_started_at).to eq(Time.iso8601(body.dig("reset_operation", "started_at")))
    expect(entry.operation_completed_at).to eq(Time.iso8601(body.dig("reset_operation", "completed_at")))
    expect(entry.occurred_at).to eq(entry.operation_completed_at)
    expect(entry.operation_completed_at).to be >= entry.operation_started_at
    expect(entry.detail).to eq(
      "participantsDeleted" => 2,
      "participantSessionsDeleted" => 2,
      "participantReactionsDeleted" => 1,
      "participantAnswersDeleted" => 1,
      "confidenceSelectionsDeleted" => 1,
      "questionRevealsReset" => 1,
      "quizSessionsReset" => 1
    )
    expect(entry.detail.keys).not_to include("participantIds", "displayNames", "emails")
  end

  it "returns the quiz snapshot captured by the reset transaction instead of querying live state after commit" do
    authenticate_operator(manager_enabled: true)
    create_full_tournament
    allow(TournamentReset).to receive(:call!).and_wrap_original do |method, **arguments|
      result = method.call(**arguments)
      create_participant("Registered after reset commit")
      QuizSession.current.start!
      result
    end

    post "/api/operator/quiz/reset", params: reset_params, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.slice("status", "phase", "current", "total_participants")).to eq(
      "status" => "waiting", "phase" => nil, "current" => nil, "total_participants" => 0
    )
    expect(QuizSession.current.reload.status).to eq("in_progress")
    expect(Participant.count).to eq(1)
  end

  private

  def create_full_tournament
    ConfidenceMultiplier.all_levels
    question = Question.create!(
      position: 1,
      question_text: "Preserved question",
      choice_a: "A",
      choice_b: "B",
      choice_c: "C",
      choice_d: "D",
      correct_answer: "A",
      points: 25,
      time_limit_seconds: 30,
      is_relay_question: true,
      is_selected_relay_question: true
    )
    second_question = Question.create!(
      position: 2,
      question_text: "Second preserved question",
      choice_a: "A2",
      choice_b: "B2",
      choice_c: "C2",
      choice_d: "D2",
      correct_answer: "B"
    )
    participant = create_participant("Player one")
    second_participant = create_participant("Player two")
    participant_session = create_participant_session(participant)
    create_participant_session(second_participant)
    ParticipantReaction.create!(
      participant:,
      participant_session:,
      reaction: "👍",
      reacted_at: Time.current
    )

    quiz_session = QuizSession.current
    quiz_session.start!
    ParticipantQuizConfidenceSelection.create!(
      participant:,
      question:,
      confidence_level: "normal",
      locked_at: Time.current
    )
    ParticipantAnswer.create!(
      participant:,
      question:,
      choice: "A",
      confidence_level: "normal",
      awarded_points: 25
    )
    quiz_session.reveal!

    { quiz_session:, question:, second_question: }
  end

  def tournament_snapshot(fixture)
    {
      counts: {
        participants: Participant.count,
        participant_sessions: ParticipantSession.count,
        participant_reactions: ParticipantReaction.count,
        participant_answers: ParticipantAnswer.count,
        confidence_selections: ParticipantQuizConfidenceSelection.count,
        audit_logs: AuditLog.count
      },
      quiz_session: fixture.fetch(:quiz_session).reload.attributes,
      question_revealed_at: fixture.fetch(:question).reload.revealed_at,
      second_question_revealed_at: fixture.fetch(:second_question).reload.revealed_at
    }
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

  def create_participant_session(participant)
    ParticipantSession.create!(
      participant:,
      token_hash: Digest::SHA256.digest(SecureRandom.urlsafe_base64(32, false)),
      expires_at: 1.hour.from_now
    )
  end

  def authenticate_admin(access_source: "MANAGEMENT_ACCESS")
    identity = AdminIdentity.create!(
      email: "admin-#{SecureRandom.uuid}@example.com",
      google_sub: "admin-#{SecureRandom.uuid}",
      admin_enabled: access_source != "APPLICANT"
    )
    device = SecureRandom.urlsafe_base64(32, false)
    session_key = SecureRandom.urlsafe_base64(32, false)
    AdminDeviceSession.create!(
      admin_identity: identity,
      device_id_hash: Digest::SHA256.digest(device),
      session_key_hash: Digest::SHA256.digest(session_key),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source:,
      expires_at: 1.hour.from_now,
      last_seen_at: Time.current
    )
    cookies[AdminAuth::DEVICE_COOKIE] = device
    cookie_name = access_source == "APPLICANT" ? AdminAuth::APPLICANT_SESSION_COOKIE : AdminAuth::SESSION_COOKIE
    cookies[cookie_name] = session_key
    identity
  end

  def authenticate_operator(manager_enabled:)
    identity = Operator::Identity.create!(
      email: "operator-#{SecureRandom.uuid}@example.com",
      google_sub: "operator-#{SecureRandom.uuid}",
      manager_enabled:
    )
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
    identity
  end
end
