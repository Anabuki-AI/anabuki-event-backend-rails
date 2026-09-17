# One answer per participant per question. Re-submissions overwrite the
# previous answer (idempotent). awarded_points is snapshotted at answer time
# as BASE_SCORE x confidence_multiplier so later multiplier edits never
# rewrite past scoring.
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
    # Scoring is snapshot at answer time: BASE_SCORE x multiplier when correct,
    # zero otherwise. Re-answers overwrite the previous result entirely.
    answer.awarded_points = if choice == question.correct_answer
      (BASE_SCORE * multiplier.confidence_multiplier).round
    else
      0
    end
    answer.save!
    answer
  end
end
