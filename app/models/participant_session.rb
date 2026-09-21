class ParticipantSession < ApplicationRecord
  WAITING_ACTIVE_WINDOW_SECONDS = 75
  belongs_to :participant

  validates :token_hash, presence: true, length: { is: 32 }
  validates :expires_at, presence: true

  def self.active_participant_count(observed_at: Time.current)
    where(revoked_at: nil)
      .where("expires_at > ?", observed_at)
      .where(waiting_heartbeat_at: (observed_at - WAITING_ACTIVE_WINDOW_SECONDS.seconds)..observed_at)
      .distinct
      .count(:participant_id)
  end
end
