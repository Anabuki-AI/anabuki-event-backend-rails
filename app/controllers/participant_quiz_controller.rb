class ParticipantQuizController < ApplicationController
  def state
    participant = participant_auth.current_session!.participant
    event = QuizEvent.order(id: :desc).first
    response.headers["Cache-Control"] = "no-store"
    render json: participant_state_json(event, participant)
  end

  def create_answer
    require_participant_same_origin!
    participant = participant_auth.current_session!.participant
    answer, confidence_level = answer_params!

    quiz_answer = QuizAnswer.transaction do
      question = QuizEventQuestion.lock.find_by(id: params[:quizEventQuestionId])
      raise QuizEventTransitionError.new("Quiz question is not available", :not_found) unless question
      raise QuizEventTransitionError, "Answers are accepted only while the question is published" unless question.published?
      raise QuizEventTransitionError, "An answer has already been submitted" if existing_answer_for(participant, question)

      multiplier = BigDecimal(question.quiz_event.confidence_multipliers.fetch(confidence_level).to_s)
      correct = answer == question.correct_answer
      QuizAnswer.create!(
        participant:,
        quiz_event_question: question,
        answer:,
        confidence_level:,
        multiplier_snapshot: multiplier,
        is_correct: correct,
        score: correct ? question.base_points * multiplier : 0
      )
    end

    render json: answer_json(quiz_answer), status: :created
  rescue ActiveRecord::RecordNotUnique
    existing_answer = QuizAnswer.find_by(participant:, quiz_event_question_id: params[:quizEventQuestionId])
    raise QuizEventTransitionError, "An answer has already been submitted" unless same_answer?(existing_answer, answer, confidence_level)

    render json: answer_json(existing_answer), status: :ok
  end

  private

  def answer_params!
    answer = params[:answer]
    confidence_level = params[:confidenceLevel]
    unless QuizAnswer::ANSWERS.include?(answer) && ConfidenceMultiplier::LEVELS.include?(confidence_level)
      raise QuizEventTransitionError.new("answer must be A, B, C, or D and confidenceLevel must be high, normal, or low", :unprocessable_content)
    end

    [ answer, confidence_level ]
  end

  # The model deliberately relies on the database's unique index for this
  # invariant. A second request can pass this check before the first commits;
  # create_answer rescues that resulting RecordNotUnique and is idempotent only
  # when both submitted values match.
  def existing_answer_for(participant, question)
    QuizAnswer.lock.find_by(participant:, quiz_event_question: question)
  end

  def same_answer?(existing_answer, answer, confidence_level)
    existing_answer && existing_answer.answer == answer && existing_answer.confidence_level == confidence_level
  end

  def participant_state_json(event, participant)
    return { event: nil, question: nil } unless event

    question = visible_question(event)
    revealed_answers = QuizAnswer.joins(:quiz_event_question)
      .where(participant:, quiz_event_questions: { quiz_event_id: event.id, status: "REVEALED" })
    event_json = {
      id: event.id,
      status: event.status_before_type_cast,
      startedAt: event.created_at.iso8601,
      finishedAt: event.finished_at&.iso8601,
      totalQuestions: event.quiz_event_questions.count,
      revealedQuestionCount: event.quiz_event_questions.revealed.count,
      confidenceMultipliers: event.confidence_multipliers
    }
    event_json[:totalScore] = format("%.2f", revealed_answers.sum(:score)) if event_json[:revealedQuestionCount].positive?

    {
      event: event_json,
      question: question && participant_question_json(question, participant)
    }
  end

  def visible_question(event)
    event.quiz_event_questions.published.order(:position).first ||
      event.quiz_event_questions.closed.order(:position).first ||
      event.quiz_event_questions.revealed.order(position: :desc).first
  end

  def participant_question_json(question, participant)
    answer = question.quiz_answers.find_by(participant:)
    json = {
      id: question.id,
      position: question.position,
      status: question.status_before_type_cast,
      questionText: question.question_text,
      choiceA: question.choice_a,
      choiceB: question.choice_b,
      choiceC: question.choice_c,
      choiceD: question.choice_d,
      imageUrl: question.image_url,
      myAnswer: answer && answer_json(answer)
    }
    if question.revealed?
      json[:correctAnswer] = question.correct_answer
      json[:myAnswer] = answer && answer_json(answer, revealed: true)
    end
    json
  end

  def answer_json(answer, revealed: false)
    json = {
      id: answer.id,
      quizEventQuestionId: answer.quiz_event_question_id,
      answer: answer.answer,
      confidenceLevel: answer.confidence_level,
      submittedAt: answer.created_at.iso8601
    }
    if revealed
      json[:isCorrect] = answer.is_correct
      json[:points] = format("%.2f", answer.score)
    end
    json
  end
end
