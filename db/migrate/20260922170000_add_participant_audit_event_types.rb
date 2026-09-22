# audit_logs.event_type has a DB-level CHECK constraint mirroring
# AuditLog::EVENT_TYPES. New event types (participant deletion by an
# operator, display-name moderation outcomes) must be allowed here too.
class AddParticipantAuditEventTypes < ActiveRecord::Migration[8.1]
  EXISTING_EVENT_TYPES = %w[
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
    TOURNAMENT_RESET
  ].freeze
  NEW_EVENT_TYPES = %w[
    PARTICIPANT_DELETED
    DISPLAY_NAME_REJECTED
    DISPLAY_NAME_MODERATION_FAILED
  ].freeze
  EVENT_TYPES = (EXISTING_EVENT_TYPES + NEW_EVENT_TYPES).freeze

  def up
    replace_event_type_constraint(EVENT_TYPES)
  end

  def down
    replace_event_type_constraint(EXISTING_EVENT_TYPES)
  end

  private

  def replace_event_type_constraint(event_types)
    remove_check_constraint :audit_logs, name: "audit_logs_event_type"
    quoted_types = event_types.map { |event_type| connection.quote(event_type) }.join(", ")
    add_check_constraint :audit_logs, "event_type IN (#{quoted_types})", name: "audit_logs_event_type"
  end
end
