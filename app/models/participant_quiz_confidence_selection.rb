# A participant's irreversible confidence-level choice for one question.
# Low confidence (Lv.1) receives a server-selected incorrect choice to remove.
class ParticipantQuizConfidenceSelection < ApplicationRecord
  belongs_to :participant
  belongs_to :question

  validates :confidence_level, inclusion: { in: ConfidenceMultiplier::LEVELS }
  validates :eliminated_choice, inclusion: { in: %w[A B C D] }, allow_nil: true
  validates :question_id, uniqueness: { scope: :participant_id }
  validate :low_confidence_has_an_incorrect_elimination

  private

  def low_confidence_has_an_incorrect_elimination
    if confidence_level == "low"
      errors.add(:eliminated_choice, "must be present for low confidence") if eliminated_choice.blank?
      errors.add(:eliminated_choice, "must not be correct") if eliminated_choice == question&.correct_answer
    elsif eliminated_choice.present?
      errors.add(:eliminated_choice, "is only permitted for low confidence")
    end
  end
end
