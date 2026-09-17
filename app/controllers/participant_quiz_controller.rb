class ParticipantQuizController < ApplicationController
  ANSWER_WINDOW_ERROR = "Answers are not being accepted for this question"

  before_action :require_participant_session!
  before_action :require_participant_same_origin!, only: :create

  def state
    quiz_session = QuizSession.current

    render json: participant_quiz_state(quiz_session, current_participant)
  end

  def create
    quiz_session = QuizSession.current
    question = quiz_session.current_question

    unless answer_window_open?(quiz_session, question)
      return render_error(ANSWER_WINDOW_ERROR, :conflict)
    end

    multipliers = ConfidenceMultiplier.all_levels
    unless multipliers.key?(params[:confidence_level])
      return render_error("confidence_level is invalid", :unprocessable_content)
    end

    answer = ParticipantAnswer.record!(
      participant: current_participant,
      question:,
      choice: params[:choice],
      confidence_level: params[:confidence_level]
    )

    render json: { answered: true, my_answer: my_answer_json(answer) }, status: :created
  rescue ActiveRecord::RecordInvalid => error
    render_error(error.record.errors.full_messages.to_sentence, :unprocessable_content)
  end

  private

  # Answers are only accepted while the current question is in the answering
  # phase; anything else (closed, revealed, wrong question, waiting/finished)
  # is a 409 per the contract.
  def answer_window_open?(quiz_session, question)
    quiz_session.status == "in_progress" &&
      quiz_session.phase == "answering" &&
      question.present? &&
      question.id == params[:question_id].to_i
  end

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
    state
  end

  def current_answer(quiz_session, participant)
    return nil unless quiz_session.current_question

    ParticipantAnswer.find_by(participant:, question: quiz_session.current_question)
  end

  def my_answer_json(answer)
    { choice: answer.choice, confidence_level: answer.confidence_level }
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
      image_url: question.image_url
    }
  end
end
