class ParticipantSession < ApplicationRecord
  WAITING_ACTIVE_WINDOW_SECONDS = 75
  REACTION_COOLDOWN = 0.5.seconds

  belongs_to :participant
  has_many :participant_reactions, dependent: :destroy

  validates :token_hash, presence: true, length: { is: 32 }
  validates :expires_at, presence: true

  # Participant-owned writes use the canonical participants -> sessions ->
  # reactions lock order shared with registration and tournament reset. The
  # participant row lock also keeps a reset from deleting it between session
  # authorization and the reaction insert.
  def record_reaction(reaction:)
    self.class.transaction do
      reacting_participant = participant
      reacting_participant.lock!
      lock!
      reacted_at = Time.current

      if reaction_rate_limited?(at: reacted_at)
        nil
      else
        event = participant_reactions.create!(participant: reacting_participant, reaction:, reacted_at:)
        update!(last_reaction_at: reacted_at)
        event
      end
    end
  end

  def self.active_participant_count(observed_at: Time.current)
    where(revoked_at: nil)
      .where("expires_at > ?", observed_at)
      .where(waiting_heartbeat_at: (observed_at - WAITING_ACTIVE_WINDOW_SECONDS.seconds)..observed_at)
      .distinct
      .count(:participant_id)
  end

  private

  def reaction_rate_limited?(at:)
    last_reaction_at && last_reaction_at >= at - REACTION_COOLDOWN
  end
end
