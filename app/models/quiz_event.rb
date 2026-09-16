class QuizEvent < ApplicationRecord
  LIFECYCLE_LOCK_KEY = 8_114_092_635

  has_many :quiz_event_questions, dependent: :destroy

  enum :status, { active: "ACTIVE", finished: "FINISHED" }, validate: true

  validates :confidence_multipliers, presence: true

  def self.with_lifecycle_lock
    connection.select_value("SELECT pg_advisory_xact_lock(#{LIFECYCLE_LOCK_KEY})")
    yield
  end
end
