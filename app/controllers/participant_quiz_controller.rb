class ParticipantQuizController < ApplicationController
  before_action :require_participant_session!

  def state
    quiz_session = QuizSession.current

    render json: participant_quiz_state(quiz_session, current_participant)
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
  def participant_quiz_state(quiz_session, _participant)
    state = { status: quiz_session.status }
    return state unless quiz_session.status == "in_progress"

    state[:phase] = quiz_session.phase
    state[:question] = question_json(quiz_session.current_question) if quiz_session.current_question
    state[:answered] = false
    state[:my_answer] = nil
    state[:correct_answer] = quiz_session.phase == "revealed" ? quiz_session.current_question&.correct_answer : nil
    state
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
