class AddTournamentResetAuditFields < ActiveRecord::Migration[8.1]
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
  ].freeze
  EVENT_TYPES = (EXISTING_EVENT_TYPES + [ "TOURNAMENT_RESET" ]).freeze

  def up
    add_column :audit_logs, :operation_id, :uuid
    add_column :audit_logs, :operation_started_at, :datetime
    add_column :audit_logs, :operation_completed_at, :datetime
    add_index :audit_logs, :operation_id, unique: true, where: "operation_id IS NOT NULL"

    replace_event_type_constraint(EVENT_TYPES)
    add_check_constraint :audit_logs,
      "event_type <> 'TOURNAMENT_RESET' OR " \
        "(operation_id IS NOT NULL AND operation_started_at IS NOT NULL AND operation_completed_at IS NOT NULL " \
        "AND NULLIF(BTRIM(actor_email), '') IS NOT NULL AND NULLIF(BTRIM(actor_google_sub), '') IS NOT NULL)",
      name: "audit_logs_tournament_reset_operation"
    add_check_constraint :audit_logs,
      "operation_completed_at IS NULL OR operation_started_at IS NULL OR operation_completed_at >= operation_started_at",
      name: "audit_logs_operation_timestamp_order"
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM audit_logs WHERE event_type = 'TOURNAMENT_RESET')")
      raise ActiveRecord::IrreversibleMigration, "cannot remove tournament reset audit metadata after a reset was recorded"
    end

    remove_check_constraint :audit_logs, name: "audit_logs_operation_timestamp_order"
    remove_check_constraint :audit_logs, name: "audit_logs_tournament_reset_operation"
    replace_event_type_constraint(EXISTING_EVENT_TYPES)
    remove_index :audit_logs, :operation_id, where: "operation_id IS NOT NULL"
    remove_column :audit_logs, :operation_completed_at
    remove_column :audit_logs, :operation_started_at
    remove_column :audit_logs, :operation_id
  end

  private

  def replace_event_type_constraint(event_types)
    remove_check_constraint :audit_logs, name: "audit_logs_event_type"
    quoted_types = event_types.map { |event_type| connection.quote(event_type) }.join(", ")
    add_check_constraint :audit_logs, "event_type IN (#{quoted_types})", name: "audit_logs_event_type"
  end
end
