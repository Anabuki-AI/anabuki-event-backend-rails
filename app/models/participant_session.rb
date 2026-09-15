class ParticipantSession < ApplicationRecord
  belongs_to :participant

  validates :token_hash, presence: true, length: { is: 32 }
  validates :expires_at, presence: true
end
