class OperatorQuizController < ApplicationController
  def state
    require_manager!
    event = QuizEvent.order(id: :desc).first
    render json: operator_state_json(event)
  end

  def start
    require_operator_same_origin!
    require_manager!

    event = QuizEvent.transaction do
      QuizEvent.with_lifecycle_lock do
        raise QuizEventTransitionError, "A quiz event is already active" if QuizEvent.active.lock.exists?

        questions = Question.order(:position).lock.to_a
        raise QuizEventTransitionError.new("No questions are available", :unprocessable_content) if questions.empty?

        ConfidenceMultiplier.all_levels
        multipliers = ConfidenceMultiplier.where(level: ConfidenceMultiplier::LEVELS).order(:level).lock.index_by(&:level)
        event = QuizEvent.create!(
          status: "ACTIVE",
          confidence_multipliers: confidence_multipliers_json(multipliers)
        )
        questions.each do |question|
          event.quiz_event_questions.create!(
            source_question_id: question.id,
            position: question.position,
            status: "PENDING",
            question_text: question.question_text,
            choice_a: question.choice_a,
            choice_b: question.choice_b,
            choice_c: question.choice_c,
            choice_d: question.choice_d,
            correct_answer: question.correct_answer,
            image_url: question.image_url,
            base_points: 100
          )
        end
        event
      end
    end

    render json: operator_state_json(event), status: :created
  end

  def publish
    transition do |event|
      raise QuizEventTransitionError, "A question is already published" if event.quiz_event_questions.published.lock.exists?
      raise QuizEventTransitionError, "The closed question must be revealed before publishing another" if event.quiz_event_questions.closed.lock.exists?

      question = event.quiz_event_questions.pending.order(:position).lock.first
      raise QuizEventTransitionError, "No pending question is available" unless question

      question.update!(status: "PUBLISHED")
    end
  end

  def close
    transition do |event|
      question = event.quiz_event_questions.published.lock.first
      raise QuizEventTransitionError, "No published question is available" unless question

      question.update!(status: "CLOSED")
    end
  end

  def reveal
    transition do |event|
      question = event.quiz_event_questions.published.order(:position).lock.first ||
        event.quiz_event_questions.closed.order(:position).lock.first
      raise QuizEventTransitionError, "No published or closed question is available" unless question

      question.update!(status: "REVEALED")
      event.update!(status: "FINISHED", finished_at: Time.current) unless event.quiz_event_questions.pending.exists?
    end
  end

  private

  def transition
    require_operator_same_origin!
    require_manager!

    event = QuizEvent.transaction do
      QuizEvent.with_lifecycle_lock do
        event = QuizEvent.active.lock.order(id: :desc).first
        raise QuizEventTransitionError, "No active quiz event is available" unless event

        yield event
        event
      end
    end
    render json: operator_state_json(event)
  end

  def require_manager!
    session = operator_auth.any_session!
    raise OperatorAuthError.new("Manager access is required", :forbidden) unless session.source == "MANAGER"

    session
  end

  def require_operator_same_origin!
    require_same_origin!(config: operator_auth_config)
  end

  def confidence_multipliers_json(multipliers)
    ConfidenceMultiplier::LEVELS.index_with do |level|
      format("%.2f", multipliers.fetch(level).confidence_multiplier)
    end
  end

  def operator_state_json(event)
    return { event: nil, questions: [] } unless event

    {
      event: {
        id: event.id,
        status: event.status_before_type_cast,
        startedAt: event.created_at.iso8601,
        finishedAt: event.finished_at&.iso8601,
        confidenceMultipliers: event.confidence_multipliers
      },
      questions: event.quiz_event_questions.order(:position).map { |question| operator_question_json(question) }
    }
  end

  def operator_question_json(question)
    {
      id: question.id,
      sourceQuestionId: question.source_question_id,
      position: question.position,
      status: question.status_before_type_cast,
      questionText: question.question_text,
      choiceA: question.choice_a,
      choiceB: question.choice_b,
      choiceC: question.choice_c,
      choiceD: question.choice_d,
      correctAnswer: question.correct_answer,
      imageUrl: question.image_url,
      basePoints: question.base_points
    }
  end
end
