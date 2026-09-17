# One immutable answer per participant per question. The score and selected
# multiplier are snapshotted at answer time, so later setting changes never
# rewrite past scoring. Question edits explicitly recalculate only answers for
# the edited question.
class ParticipantAnswer < ApplicationRecord
  class AlreadyRecorded < StandardError; end

  belongs_to :participant
  belongs_to :question

  validates :choice, inclusion: { in: %w[A B C D] }
  validates :confidence_level, inclusion: { in: ConfidenceMultiplier::LEVELS }
  validates :awarded_points, numericality: { only_integer: true }
  validates :question_id, uniqueness: { scope: :participant_id }

  def self.record!(participant:, question:, choice:, confidence_level:)
    existing = find_by(participant:, question:)
    if existing
      return existing if existing.choice == choice && existing.confidence_level == confidence_level

      raise AlreadyRecorded, "This answer has already been recorded"
    end

    multiplier = ConfidenceMultiplier.find_by!(level: confidence_level)
    answer = new(participant:, question:, choice:, confidence_level:)
    answer.awarded_points = awarded_points_for(question:, choice:, confidence_level:, multiplier:)
    answer.save!
    answer
  end

  # Question edits intentionally revise scores for that question. Multiplier
  # edits themselves still do not recalculate historical answers.
  def self.recalculate_for_question!(question, previous_correct_answer: nil)
    affected_choices = [ question.correct_answer, previous_correct_answer ].compact.uniq
    sql = sanitize_sql_array([
      <<~SQL.squish,
        UPDATE participant_answers
        SET awarded_points = CASE
          WHEN participant_answers.choice = ?
            THEN CAST(ROUND(? * confidence_multipliers.confidence_multiplier) AS integer)
          WHEN participant_answers.confidence_level = 'high'
            THEN -CAST(ROUND(? * 0.5) AS integer)
          ELSE 0
        END,
        updated_at = ?
        FROM confidence_multipliers
        WHERE participant_answers.question_id = ?
          AND (
            participant_answers.choice IN (?)
            OR participant_answers.confidence_level = 'high'
          )
          AND confidence_multipliers.level = participant_answers.confidence_level
      SQL
      question.correct_answer,
      question.points,
      question.points,
      Time.current,
      question.id,
      affected_choices
    ])

    connection.update(sql, "Recalculate scores for question")
  end

  def self.awarded_points_for(question:, choice:, confidence_level:, multiplier:)
    return (question.points * multiplier.confidence_multiplier).round if choice == question.correct_answer
    return 0 unless confidence_level == "high"

    -(question.points * BigDecimal("0.5")).round
  end
end
