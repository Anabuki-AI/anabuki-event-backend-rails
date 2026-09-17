# One answer per participant per question. Re-submissions overwrite the
# previous answer (idempotent). awarded_points is snapshotted from the
# question's points and the selected confidence multiplier. Question scoring
# edits explicitly refresh only the answers belonging to that question.
class ParticipantAnswer < ApplicationRecord
  BASE_SCORE = 100

  belongs_to :participant
  belongs_to :question

  validates :choice, inclusion: { in: %w[A B C D] }
  validates :confidence_level, inclusion: { in: ConfidenceMultiplier::LEVELS }
  validates :awarded_points, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :question_id, uniqueness: { scope: :participant_id }

  def self.record!(participant:, question:, choice:, confidence_level:)
    multiplier = ConfidenceMultiplier.find_by!(level: confidence_level)
    answer = find_or_initialize_by(participant:, question:)
    answer.choice = choice
    answer.confidence_level = confidence_level
    answer.awarded_points = awarded_points_for(
      question:,
      choice:,
      confidence_multiplier: multiplier.confidence_multiplier
    )
    answer.save!
    answer
  end

  def self.recalculate_for_question!(question, previous_correct_answer: nil)
    affected_choices = [ question.correct_answer, previous_correct_answer ].compact.uniq
    sql = sanitize_sql_array([
      <<~SQL.squish,
        UPDATE participant_answers
        SET awarded_points = CASE
          WHEN participant_answers.choice = ?
            THEN CAST(ROUND(? * confidence_multipliers.confidence_multiplier) AS integer)
          ELSE 0
        END,
        updated_at = ?
        FROM confidence_multipliers
        WHERE participant_answers.question_id = ?
          AND participant_answers.choice IN (?)
          AND confidence_multipliers.level = participant_answers.confidence_level
      SQL
      question.correct_answer,
      question.points,
      Time.current,
      question.id,
      affected_choices
    ])

    connection.update(sql, "Recalculate scores for question")
  end

  def self.awarded_points_for(question:, choice:, confidence_multiplier:)
    return 0 unless choice == question.correct_answer

    (question.points * confidence_multiplier).round
  end
end
