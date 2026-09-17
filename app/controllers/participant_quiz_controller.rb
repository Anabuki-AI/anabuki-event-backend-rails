class ParticipantQuizController < ApplicationController
  ANSWER_WINDOW_ERROR = "Answers are not being accepted for this question"

  before_action :require_participant_session!
  before_action :require_participant_same_origin!, only: :create

  def state
    quiz_session = QuizSession.current

    render json: participant_quiz_state(quiz_session, current_participant)
  end

  def create
    multipliers = ConfidenceMultiplier.all_levels
    unless multipliers.key?(params[:confidence_level])
      return render_error("confidence_level is invalid", :unprocessable_content)
    end

    answer = QuizSession.current.record_answer!(
      participant: current_participant,
      question_id: params[:question_id],
      choice: params[:choice],
      confidence_level: params[:confidence_level]
    )

    render json: { answered: true, my_answer: my_answer_json(answer) }, status: :created
  rescue QuizSession::InvalidTransition => error
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
    state[:question] = question_json(quiz_session.current_question) if quiz_session.current_question
    my_answer = current_answer(quiz_session, participant)
    state[:answered] = my_answer.present?
    state[:my_answer] = my_answer && my_answer_json(my_answer)
    state[:correct_answer] = quiz_session.phase == "revealed" ? quiz_session.current_question&.correct_answer : nil
    state[:confidence_multipliers] = ConfidenceMultiplier.all_levels.transform_values { |multiplier| multiplier.confidence_multiplier.to_f }
    state
  end

  def current_answer(quiz_session, participant)
    return nil unless quiz_session.current_question

    ParticipantAnswer.find_by(participant:, question: quiz_session.current_question)
  end

  def my_answer_json(answer)
    { choice: answer.choice, confidence_level: answer.confidence_level }
  end

  def question_image_url(question)
    return "/participant/quiz/questions/#{question.id}/image" if question.image.attached?

    question.image_url
  end

  def question_json(question)
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
      image_url: question_image_url(question)
    }
  end
end
