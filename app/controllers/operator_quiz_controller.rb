class OperatorQuizController < ApplicationController
  before_action :authorize_event_operator!
  before_action :require_operator_same_origin!, only: %i[start publish update_correct_answer close reveal finish reset]

  rescue_from QuizSession::InvalidTransition do |error|
    render_error(error.message, :unprocessable_content)
  end

  def state
    render json: quiz_state
  end

  REACTIONS_FEED_LIMIT = 50
  REACTIONS_FEED_MAX_LOOKBACK = 30.seconds

  # Read-only feed for the projector screen's floating reactions. Poll with the
  # returned cursor: the first call (no `since`) returns no history and only a
  # cursor, so reactions sent before the screen opened are never replayed.
  def reactions
    now = Time.current
    since = parse_reactions_cursor(params[:since])
    return render json: { reactions: [], cursor: now.iso8601(6) } unless since

    since = [ since, now - REACTIONS_FEED_MAX_LOOKBACK ].max
    events = ReactionEventStore.events_since(since:, now:).first(REACTIONS_FEED_LIMIT)
    cursor = events.last&.at || since
    render json: {
      reactions: events.map { |event| { id: event.id, reaction: event.reaction, reacted_at: event.at.iso8601(6) } },
      cursor: cursor.iso8601(6)
    }
  end

  def start
    quiz_session = QuizSession.current
    quiz_session.start!
    AuditLogRecorder.record(type: "QUIZ_STARTED", identity: audit_actor_identity)
    record_question_published(quiz_session)
    render json: quiz_state
  end

  def publish
    quiz_session = QuizSession.current
    quiz_session.publish_next!
    record_question_published(quiz_session)
    render json: quiz_state
  end

  def update_correct_answer
    quiz_session = QuizSession.current
    quiz_session.update_live_correct_answer!(params[:correct_answer])
    AuditLogRecorder.record(
      type: "LIVE_CORRECT_ANSWER_UPDATED",
      identity: audit_actor_identity,
      target_type: "QUESTION",
      target_id: quiz_session.current_question_id,
      detail: { "correctAnswer" => params[:correct_answer] }
    )
    render json: quiz_state
  end

  def close
    if params[:immediate] == true
      # Backward-compatible automatic expiry hint, NOT a force-close flag.
      # The model rejects early/browser-skewed expiry using the server clock.
      # ANSWER_WINDOW_CLOSED is recorded by QuizSession itself once the model
      # actually transitions the phase, so no separate entry is needed here.
      QuizSession.current.close!
    else
      # A manual operator close starts the shared ten-second countdown; the
      # eventual close is recorded separately (ANSWER_WINDOW_CLOSED) once the
      # countdown elapses and the phase actually transitions.
      quiz_session = QuizSession.current
      quiz_session.request_close!
      AuditLogRecorder.record(
        type: "ANSWER_WINDOW_CLOSE_REQUESTED",
        identity: audit_actor_identity,
        target_type: "QUESTION",
        target_id: quiz_session.current_question_id
      )
    end
    render json: quiz_state
  end

  def reveal
    quiz_session = QuizSession.current
    quiz_session.reveal!
    AuditLogRecorder.record(
      type: "ANSWER_REVEALED",
      identity: audit_actor_identity,
      target_type: "QUESTION",
      target_id: quiz_session.current_question_id,
      detail: { "correctAnswer" => quiz_session.current_question&.correct_answer }
    )
    render json: quiz_state
  end

  def finish
    quiz_session = QuizSession.current
    quiz_session.finish!
    AuditLogRecorder.record(
      type: "QUIZ_FINISHED",
      identity: audit_actor_identity,
      detail: { "finishedElapsedSeconds" => quiz_session.finished_elapsed_seconds }
    )
    render json: quiz_state
  end

  # Production-safe destructive reset. Authorization and same-origin checks run
  # before the exact server-side confirmation value is evaluated.
  def reset
    result = TournamentReset.call!(actor: audit_actor_identity, confirmation: params[:confirmation])
    render json: result.quiz_state.merge(
      reset_operation: {
        operation_id: result.operation_id,
        started_at: result.started_at.iso8601(6),
        completed_at: result.completed_at.iso8601(6),
        affected_rows: result.affected_rows
      }
    )
  rescue TournamentReset::InvalidConfirmation => error
    render_error(error.message, :unprocessable_content)
  end

  def image
    question = Question.find(params[:id])
    quiz_session = QuizSession.current
    allowed = [ quiz_session.current_question, quiz_session.next_question ].compact.any? { |candidate| candidate.id == question.id }
    return head :not_found unless allowed

    render_attached_question_image(question)
  end

  private

  # Shared by #start (first question) and #publish (every question after):
  # both are the one place "a question became visible to participants" can
  # happen, so this is the single point that records QUESTION_PUBLISHED.
  def record_question_published(quiz_session)
    question = quiz_session.current_question
    return unless question

    AuditLogRecorder.record(
      type: "QUESTION_PUBLISHED",
      identity: audit_actor_identity,
      target_type: "QUESTION",
      target_id: question.id,
      detail: { "position" => question.position, "isRelayQuestion" => question.is_relay_question }
    )
  end

  def parse_reactions_cursor(value)
    return nil if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  # Single serializer shared by GET state and every POST transition, matching
  # the Phase 0 operator contract. correct_answer is operator-only and always
  # included here; the participant API exposes it only while revealed.
  def quiz_state
    quiz_session = QuizSession.current.close_expired_answer_window!
    current_question = quiz_session.current_question
    {
      status: quiz_session.status,
      phase: quiz_session.phase,
      phase_started_at: quiz_session.phase_started_at&.iso8601,
      finished_elapsed_seconds: quiz_session.finished_elapsed_seconds,
      current: current_question && current_question_json(current_question),
      next_question: current_question && next_question_json,
      question_count: Question.count,
      total_participants: Participant.count
    }
  end

  def current_question_json(question)
    answered_count = answered_count_for(question)
    total_participants = Participant.count
    {
      question_id: question.id,
      position: question.position,
      question_text: question.question_text,
      choices: {
        "A" => question.choice_a,
        "B" => question.choice_b,
        "C" => question.choice_c,
        "D" => question.choice_d
      },
      image_url: question_image_url(question),
      is_relay_question: question.is_relay_question,
      is_selected_relay_question: question.is_selected_relay_question,
      revealed_at: question.revealed_at&.iso8601,
      live_correct_answer_confirmed: question.live_correct_answer_confirmed_at.present?,
      correct_answer: question.correct_answer,
      explanation: question.explanation,
      target_audience: question.target_audience,
      time_limit_seconds: question.time_limit_seconds,
      answered_count:,
      answered_rate: answered_rate(answered_count, total_participants)
    }
  end

  # Preview of the question that will follow the current one, so the operator
  # UI can show a "next up" card. Deliberately omits correct_answer (and the
  # answered_count/answered_rate stats, which only make sense once a question
  # is actually live) to keep answers hidden until a question is published.
  def next_question_json
    next_question = QuizSession.current.next_question
    return nil unless next_question

    {
      question_id: next_question.id,
      position: next_question.position,
      question_text: next_question.question_text,
      choices: {
        "A" => next_question.choice_a,
        "B" => next_question.choice_b,
        "C" => next_question.choice_c,
        "D" => next_question.choice_d
      },
      image_url: question_image_url(next_question),
      target_audience: next_question.target_audience
    }
  end

  # Per-answer aggregation reads the participant_answers table.
  def answered_count_for(question)
    ParticipantAnswer.where(question:).count
  end

  def answered_rate(answered_count, total_participants)
    return 0.0 if total_participants.zero?

    (answered_count.to_f / total_participants).round(2)
  end

  def question_image_url(question)
    return "/operator/quiz/questions/#{question.id}/image" if question.image.attached?

    question.image_url
  end

  def require_operator_same_origin!
    origin = request.headers["Origin"]
    return if origin.blank? || operator_auth_config.allowed_origin?(origin) || admin_auth_config.allowed_origin?(origin)

    raise AdminAuthError.new("Origin is not allowed", :forbidden)
  end
end
