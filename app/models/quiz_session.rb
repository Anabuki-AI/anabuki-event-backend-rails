# Single-row aggregate representing the one live quiz progression of the whole
# event. Operators drive transitions; participants only read state through
# their own API. Invalid transitions raise InvalidTransition, which controllers
# translate to HTTP 422.
class QuizSession < ApplicationRecord
  STATUSES = %w[waiting in_progress finished].freeze
  PHASES = %w[answering closed revealed].freeze

  class InvalidTransition < StandardError; end

  belongs_to :current_question, class_name: "Question", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :phase, inclusion: { in: PHASES }, allow_nil: true
  validate :phase_only_while_in_progress

  # Lazily materializes the singleton session row.
  def self.current
    create_or_find_by!(singleton: true)
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

  def publish!(position:)
    transaction do
      lock!
      require_status!("in_progress", "Quiz is not in progress")

      question = Question.find_by(position: position)
      raise InvalidTransition, "Question with position #{position} does not exist" unless question

      update!(current_question: question, phase: "answering", phase_started_at: Time.current)
    end
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
      update!(status: "waiting", current_question: nil, phase: nil, phase_started_at: Time.current)
    end
  end

  private

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
