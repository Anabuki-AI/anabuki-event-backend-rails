class QuizAnswer < ApplicationRecord
  ANSWERS = %w[A B C D].freeze

  belongs_to :participant
  belongs_to :quiz_event_question

  validates :answer, inclusion: { in: ANSWERS }
  validates :confidence_level, inclusion: { in: ConfidenceMultiplier::LEVELS }
  validates :multiplier_snapshot, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: BigDecimal("9.99") }
  validates :score, numericality: { greater_than_or_equal_to: 0 }
end
