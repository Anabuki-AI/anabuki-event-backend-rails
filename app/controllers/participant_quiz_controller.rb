class ParticipantQuizController < ApplicationController
  ANSWER_WINDOW_ERROR = "Answers are not being accepted for this question"

  before_action :require_participant_session!
  before_action :require_participant_same_origin!, only: [ :create, :confirm_confidence_level ]

  def state
    quiz_session = QuizSession.current

    render json: participant_quiz_state(quiz_session, current_participant)
  end

  # Confidence is selected before the participant sees an Lv.1-reduced answer
  # list. The returned state is immediately usable by the polling client.
  def confirm_confidence_level
    confidence_level = params[:confidence_level]
    unless ConfidenceMultiplier.all_levels.key?(confidence_level)
      return render_error("confidence_level is invalid", :unprocessable_content)
    end

    quiz_session = QuizSession.current
    quiz_session.confirm_confidence_level!(
      participant: current_participant,
      question_id: params[:question_id],
      confidence_level:
    )

    render json: participant_quiz_state(quiz_session.reload, current_participant)
  rescue QuizSession::InvalidTransition => error
    render_error(error.message.presence || ANSWER_WINDOW_ERROR, :conflict)
  rescue ActiveRecord::RecordInvalid => error
    render_error(error.record.errors.full_messages.to_sentence, :unprocessable_content)
  end

  def create
    answer = QuizSession.current.record_answer!(
      participant: current_participant,
      question_id: params[:question_id],
      choice: params[:choice]
    )

    status = answer.previously_new_record? ? :created : :ok
    render json: { answered: true, my_answer: my_answer_json(answer) }, status:
  rescue QuizSession::InvalidTransition, ParticipantAnswer::AlreadyRecorded => error
    render_error(error.message.presence || ANSWER_WINDOW_ERROR, :conflict)
  rescue ActiveRecord::RecordInvalid => error
    render_error(error.record.errors.full_messages.to_sentence, :unprocessable_content)
  end

  def image
    quiz_session = QuizSession.current
    question = Question.find(params[:id])
    return head :not_found unless quiz_session.status == "in_progress" && quiz_session.current_question&.id == question.id

    render_attached_question_image(question)
  end

  private


  def require_participant_session!
    current_participant
  end

  def current_participant
    @current_participant ||= participant_auth.current_session!.participant
  end

  # Participant-facing state serializer. correct_answer is only exposed while
  # the phase is revealed; every other phase returns null so participants
  # never see the answer early.
  def participant_quiz_state(quiz_session, participant)
    state = { status: quiz_session.status }
    return state unless quiz_session.status == "in_progress"

    state[:phase] = quiz_session.phase
    # Shared with the operator state so a closing countdown is synchronized to
    # the server timestamp instead of the participant browser's start time.
    state[:phase_started_at] = quiz_session.phase_started_at&.iso8601
    question = quiz_session.current_question
    selection = current_confidence_selection(question, participant)
    state[:question] = question_json(question, selection:) if question
    my_answer = current_answer(quiz_session, participant)
    state[:answered] = my_answer.present?
    state[:my_answer] = my_answer && my_answer_json(my_answer)
    state[:correct_answer] = quiz_session.phase == "revealed" ? question&.correct_answer : nil
    state[:confidence_level] = selection&.confidence_level || my_answer&.confidence_level
    state[:confidence_locked] = selection.present? || my_answer.present?
    state[:confidence_multipliers] = ConfidenceMultiplier.all_levels.transform_values { |multiplier| multiplier.confidence_multiplier.to_f }
    state
  end

  def current_answer(quiz_session, participant)
    return nil unless quiz_session.current_question

    ParticipantAnswer.find_by(participant:, question: quiz_session.current_question)
  end

  def current_confidence_selection(question, participant)
    return nil unless question

    ParticipantQuizConfidenceSelection.find_by(participant:, question:)
  end

  def my_answer_json(answer)
    { choice: answer.choice, confidence_level: answer.confidence_level }
  end

  def question_image_url(question)
    return "/participant/quiz/questions/#{question.id}/image" if question.image.attached?

    question.image_url
  end

  def question_json(question, selection: nil)
    choices = {
      "A" => question.choice_a,
      "B" => question.choice_b,
      "C" => question.choice_c,
      "D" => question.choice_d
    }
    choices.delete(selection.eliminated_choice) if selection&.eliminated_choice

    {
      question_id: question.id,
      position: question.position,
      question_text: question.question_text,
      choices:,
      image_url: question_image_url(question)
    }
  end
end
