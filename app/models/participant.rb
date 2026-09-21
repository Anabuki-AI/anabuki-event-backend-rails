class Participant < ApplicationRecord
  has_many :participant_sessions, dependent: :destroy

  validates :display_name, presence: true, length: { maximum: 100 }
  validates :gender, :age_group, presence: true, length: { maximum: 50 }
  validates :student_type, length: { maximum: 50 }
  validates :school, :department, length: { maximum: 255 }
  validates :agreed_terms, inclusion: { in: [ true ] }
end
