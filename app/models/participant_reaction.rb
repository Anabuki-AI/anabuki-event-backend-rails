class ParticipantReaction < ApplicationRecord
  REACTIONS = %w[👏 🎉 🙌 😂 😢 😲 👍 ❤️].freeze

  belongs_to :participant
  belongs_to :participant_session

  validates :reaction, inclusion: { in: REACTIONS }
  validates :reacted_at, presence: true
  validate :participant_matches_session

  private

  def participant_matches_session
    return unless participant && participant_session
    return if participant_id == participant_session.participant_id

    errors.add(:participant, "must match participant session")
  end
end
