# One append-only entry per succeeded admin action. `event_type` is a closed
# enum shared with docs/audit-log-contract.md; adding a value requires a
# contract update before the frontend can label it.
class AuditLog < ApplicationRecord
  EVENT_TYPES = %w[
    ADMIN_LOGIN_SUCCEEDED
    ADMIN_LOGGED_OUT
    ADMIN_ACCESS_EXCHANGED
    QUESTION_CREATED
    QUESTION_UPDATED
    QUESTION_DELETED
    CONFIDENCE_MULTIPLIER_UPDATED
    ACCESS_REQUEST_APPROVED
    ACCESS_REQUEST_REJECTED
    MANAGEMENT_ACCESS_REVOKED
    OPERATOR_ACCESS_GRANTED
    OPERATOR_ACCESS_REVOKED
  ].freeze

  belongs_to :admin_identity, optional: true

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :occurred_at, presence: true
  validate :detail_contains_only_safe_scalars

  private

  # The contract requires detail to be presentation-safe: scalar values only,
  # never credentials or blobs. Enforced here as a last line of defense; the
  # recorder sanitizes before writing.
  def detail_contains_only_safe_scalars
    return if detail.is_a?(Hash) && detail.values.all? { |value| safe_scalar?(value) }

    errors.add(:detail, "must be an object with scalar values only")
  end

  def safe_scalar?(value)
    value.nil? || value == true || value == false || value.is_a?(String) || value.is_a?(Numeric)
  end
end
