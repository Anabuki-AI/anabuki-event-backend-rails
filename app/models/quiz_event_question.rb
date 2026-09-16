class QuizEventQuestion < ApplicationRecord
  STATUSES = %w[PENDING PUBLISHED CLOSED REVEALED].freeze

  belongs_to :quiz_event
  has_many :quiz_answers, dependent: :destroy

  enum :status, { pending: "PENDING", published: "PUBLISHED", closed: "CLOSED", revealed: "REVEALED" }, validate: true

  validates :source_question_id, :position, :question_text, :choice_a, :choice_b, :choice_c, :choice_d, :correct_answer, :base_points, presence: true
  validates :position, :base_points, numericality: { only_integer: true, greater_than: 0 }
  validates :correct_answer, inclusion: { in: %w[A B C D] }
end
