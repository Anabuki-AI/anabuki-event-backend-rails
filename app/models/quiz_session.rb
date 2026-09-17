# Single-row aggregate representing the one live quiz progression of the whole
# event. Operators drive transitions; participants only read state through
# their own API. Invalid transitions raise InvalidTransition, which controllers
# translate to HTTP 422.
class QuizSession < ApplicationRecord
  STATUSES = %w[waiting in_progress finished].freeze
  PHASES = %w[answering closed revealed].freeze
  SINGLETON_LOCK_KEY = 4_246_813_579

  class InvalidTransition < StandardError; end

  belongs_to :current_question, class_name: "Question", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :phase, inclusion: { in: PHASES }, allow_nil: true
  validate :phase_only_while_in_progress

  # Lazily materializes the singleton session row. The initial lookup avoids
  # an INSERT for the common read path. A transaction-level advisory lock
  # serializes the first lookup when multiple requests initialize the quiz at
  # the same time, so the unique index is a last-resort invariant rather than
  # the normal concurrency mechanism.
  def self.current
    find_by(singleton: true) || transaction(requires_new: true) do
      connection.execute("SELECT pg_advisory_xact_lock(#{SINGLETON_LOCK_KEY})")
      find_or_create_by!(singleton: true)
    end
  end

  def start!
    transaction do
      lock!
      require_status!("waiting", "Quiz has already been started")

      question = Question.order(:position).first
      raise InvalidTransition, "No questions are registered" unless question

      update!(status: "in_progress", current_question: question, phase: "answering", phase_started_at: Time.current)
    end
  end

  # Publishes the first real question after the current one. The position is
  # deliberately resolved here rather than inferred by a client, because
  # deleting a question can leave gaps in the position sequence.
  def publish_next!
    transaction do
      lock!
      require_status!("in_progress", "Quiz is not in progress")

      question = next_question
      raise InvalidTransition, "There are no more questions" unless question

      update!(current_question: question, phase: "answering", phase_started_at: Time.current)
    end
  end

  def next_question
    return nil unless current_question

    Question.where("position > ?", current_question.position).order(:position).first
  end

  def record_answer!(participant:, question_id:, choice:, confidence_level:)
    expired = false
    answer = transaction do
      lock!
      question = current_question

      unless answer_window_matches?(question, question_id)
        raise InvalidTransition, "Answers are not being accepted for this question"
      end

      if answer_window_expired?(question)
        update!(phase: "closed", phase_started_at: Time.current)
        expired = true
        nil
      else
        ParticipantAnswer.record!(participant:, question:, choice:, confidence_level:)
      end
    end

    raise InvalidTransition, "Answers are not being accepted for this question" if expired

    answer
  end

  def close!
    transaction do
      lock!
      require_status!("in_progress", "Quiz is not in progress")
      require_phase!("answering", "Answers are already closed")

      update!(phase: "closed", phase_started_at: Time.current)
    end
  end

  def reveal!
    transaction do
      lock!
      require_status!("in_progress", "Quiz is not in progress")
      unless phase.in?(%w[answering closed])
        raise InvalidTransition, "Answer is already revealed"
      end

      update!(phase: "revealed", phase_started_at: Time.current)
      current_question.update!(revealed_at: Time.current)
    end
  end

  def finish!
    transaction do
      lock!
      require_status_not_finished!

      update!(status: "finished", current_question: nil, phase: nil, phase_started_at: Time.current)
    end
  end

  # Debug-only escape hatch: forces the session back to its initial state
  # regardless of the current status/phase. Unlike the transitions above this
  # never raises InvalidTransition, since it exists to recover from any state.
  def reset!
    transaction do
      lock!
      ParticipantAnswer.delete_all
      Question.update_all(revealed_at: nil)
      update!(status: "waiting", current_question: nil, phase: nil, phase_started_at: Time.current)
    end
  end

  private

  def answer_window_matches?(question, question_id)
    status == "in_progress" && phase == "answering" && question && question.id == question_id.to_i
  end

  def answer_window_expired?(question)
    limit = question.time_limit_seconds
    limit.present? && phase_started_at.present? && Time.current >= phase_started_at + limit.seconds
  end

  def require_status!(expected, message)
    return if status == expected

    raise InvalidTransition, message
  end

  def require_status_not_finished!
    return unless status == "finished"

    raise InvalidTransition, "Quiz has already finished"
  end

  def require_phase!(expected, message)
    return if phase == expected

    raise InvalidTransition, message
  end

  def phase_only_while_in_progress
    return if status == "in_progress" || phase.nil?

    errors.add(:phase, "is only meaningful while the quiz is in progress")
  end
end
