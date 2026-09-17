class OperatorQuizController < ApplicationController
  before_action :authorize_event_operator!
  before_action :require_operator_same_origin!, only: %i[start publish close reveal finish reset]

  rescue_from QuizSession::InvalidTransition do |error|
    render_error(error.message, :unprocessable_content)
  end

  def state
    render json: quiz_state
  end

  def start
    QuizSession.current.start!
    render json: quiz_state
  end

  def publish
    QuizSession.current.publish_next!
    render json: quiz_state
  end

  def close
    QuizSession.current.close!
    render json: quiz_state
  end

  def reveal
    QuizSession.current.reveal!
    render json: quiz_state
  end

  def finish
    QuizSession.current.finish!
    render json: quiz_state
  end

  # Debug-only: forces the session back to waiting and wipes participant
  # answers so operators can replay the whole quiz during testing. This is
  # intentionally unavailable outside development/test environments.
  def reset
    return render_error("Quiz reset is disabled in this environment", :forbidden) unless reset_allowed?

    QuizSession.current.reset!
    render json: quiz_state
  end

  def image
    question = Question.find(params[:id])
    quiz_session = QuizSession.current
    allowed = [ quiz_session.current_question, quiz_session.next_question ].compact.any? { |candidate| candidate.id == question.id }
    return head :not_found unless allowed

    render_attached_question_image(question)
  end

  private

  # Single serializer shared by GET state and every POST transition, matching
  # the Phase 0 operator contract. correct_answer is operator-only and always
  # included here; the participant API exposes it only while revealed.
  def quiz_state
    quiz_session = QuizSession.current
    current_question = quiz_session.current_question
    {
      status: quiz_session.status,
      phase: quiz_session.phase,
      phase_started_at: quiz_session.phase_started_at&.iso8601,
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
      correct_answer: question.correct_answer,
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
      image_url: question_image_url(next_question)
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

  def reset_allowed?
    Rails.env.development? || Rails.env.test?
  end
end
