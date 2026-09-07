class AdminDeviceSession < ApplicationRecord
  belongs_to :admin_identity
  has_many :admin_access_requests, foreign_key: :applicant_session_id, dependent: :restrict_with_exception

  enum :access_source, { applicant: "APPLICANT", management_access: "MANAGEMENT_ACCESS", environment_access: "ENVIRONMENT_ACCESS" }, validate: true

  validates :device_id_hash, :session_key_hash, presence: true, length: { is: 32 }
  validates :email, :google_sub, :expires_at, :last_seen_at, presence: true
end
