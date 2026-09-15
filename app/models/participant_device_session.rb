class ParticipantDeviceSession < ApplicationRecord
  belongs_to :participant_identity

  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }

  validates :device_id_hash, :session_key_hash, :expires_at, :last_seen_at, presence: true
end
