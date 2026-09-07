class AdminOauthState < ApplicationRecord
  validates :state_hash, presence: true, length: { is: 32 }, uniqueness: true
  validates :expires_at, presence: true
end
