class OperatorQuizController < ApplicationController
  before_action :authorize_event_operator!

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
    position = params.require(:position)
    QuizSession.current.publish!(position: position)
    render json: quiz_state
  rescue ActionController::ParameterMissing
    render_error("position is required", :bad_request)
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
  # answers so operators can replay the whole quiz during testing.
  def reset
    ActiveRecord::Base.transaction do
      QuizSession.current.reset!
      ParticipantAnswer.delete_all
    end
    render json: quiz_state
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
      next_question: current_question && next_question_json(current_question),
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
      image_url: question.image_url,
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
  def next_question_json(question)
    next_question = Question.find_by(position: question.position + 1)
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
      image_url: next_question.image_url
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
end
