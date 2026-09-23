# audit_logs.event_type has a DB-level CHECK constraint mirroring
# AuditLog::EVENT_TYPES. Widens it to cover participant registration/session
# lifecycle, quiz progression (question publish/close/reveal/finish), answer
# and confidence-level submission/change history, and operator login/logout,
# none of which were previously recorded anywhere in audit_logs.
class AddParticipantActivityAuditEventTypes < ActiveRecord::Migration[8.1]
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
    PARTICIPANT_DELETED
    DISPLAY_NAME_REJECTED
    DISPLAY_NAME_MODERATION_FAILED
  ].freeze
  NEW_EVENT_TYPES = %w[
    PARTICIPANT_REGISTERED
    PARTICIPANT_DISPLAY_NAME_CHANGED
    PARTICIPANT_LOGGED_OUT
    QUIZ_STARTED
    QUESTION_PUBLISHED
    LIVE_CORRECT_ANSWER_UPDATED
    ANSWER_WINDOW_CLOSE_REQUESTED
    ANSWER_WINDOW_CLOSED
    ANSWER_REVEALED
    QUIZ_FINISHED
    ANSWER_SUBMITTED
    ANSWER_CHANGED
    CONFIDENCE_LEVEL_SELECTED
    CONFIDENCE_LEVEL_CHANGED
    OPERATOR_LOGIN_SUCCEEDED
    OPERATOR_LOGGED_OUT
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
