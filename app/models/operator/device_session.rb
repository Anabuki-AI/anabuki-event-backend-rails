class Operator::DeviceSession < Operator::ApplicationRecord
  belongs_to :operator_identity, class_name: "Operator::Identity"
  has_many :operator_access_requests, foreign_key: :applicant_session_id, dependent: :restrict_with_exception

  enum :access_source, { manager: "MANAGER", applicant: "APPLICANT" }, validate: true

  validates :device_id_hash, :session_key_hash, presence: true, length: { is: 32 }
  validates :email, :google_sub, :expires_at, :last_seen_at, presence: true
end
