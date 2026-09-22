class Participant < ApplicationRecord
  has_many :participant_sessions, dependent: :destroy

  validates :display_name, presence: true, length: { maximum: 100 }, uniqueness: { case_sensitive: false }
  validate :display_name_must_be_appropriate, if: :display_name_moderation_required?
  validates :gender, :age_group, presence: true, length: { maximum: 50 }
  validates :student_type, length: { maximum: 50 }
  validates :school, :department, length: { maximum: 255 }
  validates :agreed_terms, inclusion: { in: [ true ] }

  private

  def display_name_moderation_required?
    display_name.present? && will_save_change_to_display_name?
  end

  def display_name_must_be_appropriate
    return unless DisplayNameModeration.new.inappropriate?(display_name)

    errors.add(:display_name, :inappropriate)
  end
end
