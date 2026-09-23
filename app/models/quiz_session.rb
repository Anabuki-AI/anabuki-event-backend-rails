# Single-row aggregate representing the one live quiz progression of the whole
# event. Operators drive transitions; participants only read state through
# their own API. Invalid transitions raise InvalidTransition, which controllers
# translate to HTTP 422.
class QuizSession < ApplicationRecord
  STATUSES = %w[waiting in_progress finished].freeze
  PHASES = %w[answering closing closed revealed].freeze
  ANSWER_CLOSE_DELAY = 10.seconds
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

      started_at = Time.current
      update!(
        status: "in_progress", current_question: question, phase: "answering",
        phase_started_at: started_at, answering_started_at: started_at,
        finished_elapsed_seconds: nil
      )
      select_live_relay_question!(question)
    end
  end

  # Publishes the first real question after the current one. The position is
  # deliberately resolved here rather than inferred by a client, because
  # deleting a question can leave gaps in the position sequence.
  def publish_next!
    transaction do
      lock!
      require_status!("in_progress", "Quiz is not in progress")

      require_phase!("revealed", "Reveal the current answer before publishing the next question")

      question = next_question
      raise InvalidTransition, "There are no more questions" unless question

      started_at = Time.current
      update!(current_question: question, phase: "answering", phase_started_at: started_at, answering_started_at: started_at)
      select_live_relay_question!(question)
    end
  end

  # Relay questions do not have to know their final answer before they are
  # shown live. The operator may set it while answers are still being accepted
  # (or after the window closes, before reveal), but never after the answer has
  # been shown to participants.
  def update_live_correct_answer!(correct_answer)
    transaction do
      lock!
      require_status!("in_progress", "Quiz is not in progress")
      unless phase.in?(%w[answering closing closed])
        raise InvalidTransition, "Correct answer can only be changed before reveal"
      end

      question = current_question
      unless question&.is_relay_question? && question.is_selected_relay_question?
        raise InvalidTransition, "Only the selected, live relay question can have its correct answer changed"
      end
      raise InvalidTransition, "Correct answer must be A, B, C, or D" unless correct_answer.is_a?(String) && correct_answer.in?(%w[A B C D])

      question.update_live_correct_answer!(correct_answer)
    end
  end

  def next_question
    return nil unless current_question

    Question.where("position > ?", current_question.position).order(:position).first
  end

  # Selects or updates the confidence level for the current question. Lv.2/Lv.3
  # can be switched freely until an answer is recorded; Lv.1 is one-way and
  # eliminates one server-chosen incorrect option. `choice` (the participant's
  # currently selected option, optional) scopes that elimination so the
  # selected option is never the one removed.
  def select_confidence_level!(participant:, question_id:, confidence_level:, choice: nil)
    expired = false
    selection = transaction do
      lock!
      question = current_question

      if answer_deadline && Time.current >= answer_deadline
        close_expired_answer_window_under_lock!
        expired = true
        nil
      elsif !answer_window_matches?(question, question_id)
        raise InvalidTransition, "Answers are not being accepted for this question"
      elsif ParticipantAnswer.exists?(participant:, question:)
        raise InvalidTransition, "Confidence level cannot be changed after answering"
      elsif confidence_level == "low" && live_relay_question?(question)
        raise InvalidTransition, "Lv.1 cannot be selected for a live relay question"
      else
        existing = ParticipantQuizConfidenceSelection.find_by(participant:, question:)
        if existing.nil?
          ParticipantQuizConfidenceSelection.create!(
            participant:,
            question:,
            confidence_level:,
            eliminated_choice: eliminated_choice_for(question, confidence_level, choice:),
            locked_at: Time.current
          )
        elsif existing.confidence_level == confidence_level
          # Idempotent retry (including Lv.1, whose elimination never redraws).
          existing
        elsif existing.confidence_level == "low"
          raise InvalidTransition, "Confidence level has already been selected"
        else
          existing.update!(
            confidence_level:,
            eliminated_choice: eliminated_choice_for(question, confidence_level, choice:)
          )
          existing
        end
      end
    end

    raise InvalidTransition, "Answers are not being accepted for this question" if expired

    selection
  end

  # Records (or re-submits) the participant's answer. `confidence_level` is
  # optional: when it differs from the stored selection it is applied together
  # with the answer. Lv.2/Lv.3 can be switched freely, and ordinary questions
  # may switch into Lv.1 ("なし") once; Lv.1 can never be changed away from
  # after its elimination is chosen.
  def record_answer!(participant:, question_id:, choice:, confidence_level: nil)
    expired = false
    answer = transaction do
      lock!
      question = current_question

      if answer_deadline && Time.current >= answer_deadline
        close_expired_answer_window_under_lock!
        expired = true
        nil
      elsif !answer_window_matches?(question, question_id)
        raise InvalidTransition, "Answers are not being accepted for this question"
      else
        selection = ParticipantQuizConfidenceSelection.find_by(participant:, question:)
        raise InvalidTransition, "Select a confidence level before answering" unless selection
        raise InvalidTransition, "This choice was eliminated by Lv.1" if selection.eliminated_choice == choice

        if confidence_level.present? && confidence_level != selection.confidence_level
          if selection.confidence_level == "low"
            raise InvalidTransition, "Lv.1 confidence level cannot be changed"
          elsif confidence_level == "low"
            raise InvalidTransition, "Lv.1 cannot be selected for a live relay question" if live_relay_question?(question)

            selection.update!(
              confidence_level:,
              eliminated_choice: eliminated_choice_for(question, confidence_level, choice:)
            )
          else
            selection.update!(confidence_level:, eliminated_choice: nil)
          end
        end

        ParticipantAnswer.record!(participant:, question:, choice:, confidence_level: selection.confidence_level)
      end
    end

    raise InvalidTransition, "Answers are not being accepted for this question" if expired

    answer
  end

  # Reads and transitions can finalize an expired window without a Que worker.
  # Recheck under the same row lock used by answers/reset/publish: a stale poll
  # must never close a newer question. The deadline, not poll time, is canonical.
  def close_expired_answer_window!
    return self unless answer_deadline && Time.current >= answer_deadline

    with_lock { close_expired_answer_window_under_lock! }
    self
  end

  # Starts the ten-second, participant-visible countdown requested by an
  # operator. The job is an optimization; requests also enforce the deadline.
  def request_close!
    question_id, closing_started_at = transaction do
      lock!
      require_status!("in_progress", "Quiz is not in progress")
      require_phase!("answering", "Answers are already being closed")

      started_at = Time.current
      # Keep the original answer-window start for an independent question time
      # limit; phase_started_at now becomes the close-countdown start.
      update!(
        phase: "closing", phase_started_at: started_at,
        answering_started_at: answering_started_at || phase_started_at
      )
      [ current_question_id, started_at ]
    end

    CloseQuizAnswersJob.set(wait_until: closing_started_at + ANSWER_CLOSE_DELAY)
      .perform_later(question_id, closing_started_at.iso8601(6))
  end

  # Automatic expiry only (the legacy API calls this with immediate: true).
  # A browser clock is just a hint: verify the configured question deadline
  # under the row lock. Manual close must use request_close! instead.
  def close!
    transaction do
      lock!
      require_status!("in_progress", "Quiz is not in progress")
      raise InvalidTransition, "Answers are already closed" unless phase.in?(%w[answering closing])

      deadline = question_deadline
      unless deadline && Time.current >= deadline
        raise InvalidTransition, "Question time limit has not expired"
      end

      close_expired_answer_window_under_lock!
    end
  end

  # Idempotently finalizes only the exact delayed close that scheduled this job.
  # A job from an earlier question/reset can therefore never close a newer one.
  def complete_requested_close!(question_id:, closing_started_at:)
    transaction do
      lock!
      return unless status == "in_progress" && phase == "closing"
      return unless current_question_id == question_id
      return unless phase_started_at == closing_started_at
      return if Time.current < phase_started_at + ANSWER_CLOSE_DELAY

      close_expired_answer_window_under_lock!
    end
  end

  def reveal!
    transaction do
      lock!
      require_status!("in_progress", "Quiz is not in progress")
      close_expired_answer_window_under_lock!
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

      finished_at = Time.current
      elapsed_seconds = [ (finished_at - phase_started_at).floor, 0 ].max if phase_started_at
      update!(
        status: "finished",
        current_question: nil,
        phase: nil,
        phase_started_at: finished_at,
        answering_started_at: nil,
        finished_elapsed_seconds: elapsed_seconds
      )
    end
  end

  # Debug-only escape hatch: forces the session back to its initial state
  # regardless of the current status/phase. Unlike the transitions above this
  # never raises InvalidTransition, since it exists to recover from any state.
  def reset!
    transaction do
      lock!
      ParticipantAnswer.delete_all
      ParticipantQuizConfidenceSelection.delete_all
      Question.update_all(revealed_at: nil, live_correct_answer_confirmed_at: nil)
      update!(
        status: "waiting",
        current_question: nil,
        phase: nil,
        phase_started_at: Time.current,
        answering_started_at: nil,
        finished_elapsed_seconds: nil
      )
    end
  end

  # Used when the live question is bulk-deleted: return the progression to the
  # initial "waiting" state (same session columns as reset!, but participant
  # data is left alone). Caller must already hold the lock.
  def clear_live_question!
    update!(
      status: "waiting", current_question: nil, phase: nil, phase_started_at: Time.current,
      answering_started_at: nil, finished_elapsed_seconds: nil
    )
  end

  private

  def answer_deadline
    return unless status == "in_progress" && phase.in?(%w[answering closing])

    deadlines = []
    deadlines << phase_started_at + ANSWER_CLOSE_DELAY if phase == "closing" && phase_started_at
    deadlines << question_deadline if question_deadline
    deadlines.min
  end

  def question_deadline
    started_at = answering_started_at || phase_started_at
    limit = current_question&.time_limit_seconds
    started_at + limit.seconds if started_at && limit
  end

  def close_expired_answer_window_under_lock!
    deadline = answer_deadline
    update!(phase: "closed", phase_started_at: deadline) if deadline && Time.current >= deadline
  end

  def answer_window_matches?(question, question_id)
    status == "in_progress" && phase.in?(%w[answering closing]) && question && question.id == question_id.to_i
  end

  def eliminated_choice_for(question, confidence_level, choice: nil)
    return nil unless confidence_level == "low"

    candidates = %w[A B C D] - [ question.correct_answer ]
    candidates -= [ choice ] if choice.present?
    candidates.sample
  end

  def live_relay_question?(question)
    question&.is_relay_question? && question.is_selected_relay_question?
  end

  # The "this round's" relay flag follows whatever is actually on screen:
  # going live selects it (and Question unselects every other relay question),
  # so the operator never has to pick it in advance.
  def select_live_relay_question!(question)
    return unless question&.is_relay_question? && !question.is_selected_relay_question?

    question.update!(is_selected_relay_question: true)
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
