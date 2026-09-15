class Operator::AccessRequest < Operator::ApplicationRecord
  belongs_to :applicant_session, class_name: "Operator::DeviceSession", optional: true

  enum :status, { pending: "PENDING", approved: "APPROVED", rejected: "REJECTED", cancelled: "CANCELLED" }, validate: true

  validates :email, :google_sub, :expires_at, presence: true
  validates :applicant_session, :applicant_device_id_hash, :applicant_session_key_hash, presence: true, if: :pending?
  validates :applicant_device_id_hash, :applicant_session_key_hash, length: { is: 32 }, allow_nil: true
  validates :cancelled_at, :cancellation_reason, presence: true, if: :cancelled?
end
