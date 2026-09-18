# Destructively returns the live tournament to its pre-registration state while
# preserving questions, configuration, staff identities/sessions, and prior
# audit history. The audit entry is deliberately written with record! inside
# the same transaction: an audit failure rolls the entire reset back.
class TournamentReset
  CONFIRMATION = "RESET"
  EVENT_TYPE = "TOURNAMENT_RESET"

  Result = Data.define(:operation_id, :started_at, :completed_at, :affected_rows, :quiz_state)

  class InvalidConfirmation < StandardError; end
  class InvalidActor < ArgumentError; end

  class << self
    def call!(actor:, confirmation:)
      raise InvalidConfirmation, "confirmation must exactly equal RESET" unless confirmation == CONFIRMATION

      validate_actor!(actor)
      operation_id = SecureRandom.uuid
      started_at = Time.current
      result = nil

      ApplicationRecord.transaction(requires_new: true) do
        quiz_session = QuizSession.current
        quiz_session.lock!
        lock_participant_tables!

        affected_rows = purge_participant_data!
        affected_rows[:question_reveals] = Question.where.not(revealed_at: nil)
          .update_all(revealed_at: nil, updated_at: Time.current)
        quiz_session.update!(
          status: "waiting",
          current_question: nil,
          phase: nil,
          phase_started_at: nil,
          answering_started_at: nil,
          finished_elapsed_seconds: nil
        )
        affected_rows[:quiz_sessions] = 1
        completed_at = Time.current

        AuditLogRecorder.record!(
          type: EVENT_TYPE,
          identity: actor,
          target_type: "TOURNAMENT",
          target_id: operation_id,
          operation_id:,
          operation_started_at: started_at,
          operation_completed_at: completed_at,
          occurred_at: completed_at,
          detail: audit_detail(affected_rows)
        )

        result = Result.new(
          operation_id:,
          started_at:,
          completed_at:,
          affected_rows:,
          quiz_state: quiz_state_snapshot(quiz_session)
        )
      end

      result
    end

    private

    # ACCESS EXCLUSIVE prevents a registration or participant write that began
    # during the reset from escaping the purge. Acquire tables in the same order
    # as live writes: registration locks participants -> participant_sessions,
    # reactions lock participants -> participant_sessions -> reactions, and
    # answer submission reads confidence selections before inserting an answer.
    def lock_participant_tables!
      ApplicationRecord.connection.execute(<<~SQL.squish)
        LOCK TABLE participants, participant_sessions, participant_reactions,
          participant_quiz_confidence_selections, participant_answers
          IN ACCESS EXCLUSIVE MODE
      SQL
    end

    def purge_participant_data!
      {
        participant_reactions: ParticipantReaction.delete_all,
        participant_answers: ParticipantAnswer.delete_all,
        confidence_selections: ParticipantQuizConfidenceSelection.delete_all,
        participant_sessions: ParticipantSession.delete_all,
        participants: Participant.delete_all
      }
    end

    def validate_actor!(actor)
      email = actor&.respond_to?(:email) ? actor.email : nil
      google_sub = actor&.respond_to?(:google_sub) ? actor.google_sub : nil
      return if email.present? && google_sub.present?

      raise InvalidActor, "tournament reset actor with email and google_sub is required"
    end

    def quiz_state_snapshot(quiz_session)
      {
        status: quiz_session.status,
        phase: quiz_session.phase,
        phase_started_at: quiz_session.phase_started_at&.iso8601,
        finished_elapsed_seconds: quiz_session.finished_elapsed_seconds,
        current: nil,
        next_question: nil,
        question_count: Question.count,
        total_participants: Participant.count
      }
    end

    def audit_detail(affected_rows)
      {
        "participantsDeleted" => affected_rows.fetch(:participants),
        "participantSessionsDeleted" => affected_rows.fetch(:participant_sessions),
        "participantReactionsDeleted" => affected_rows.fetch(:participant_reactions),
        "participantAnswersDeleted" => affected_rows.fetch(:participant_answers),
        "confidenceSelectionsDeleted" => affected_rows.fetch(:confidence_selections),
        "questionRevealsReset" => affected_rows.fetch(:question_reveals),
        "quizSessionsReset" => affected_rows.fetch(:quiz_sessions)
      }
    end
  end
end
