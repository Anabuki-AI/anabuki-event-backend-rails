# Append-only operation log for the admin console (docs/audit-log-contract.md).
# Responses map event_type/actor_* columns to the contract's camelCase JSON keys.
class CreateAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_logs do |t|
      t.string :event_type, null: false
      t.references :admin_identity, null: true, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :actor_email
      t.string :actor_google_sub
      t.string :target_type
      t.string :target_id
      t.jsonb :detail, null: false, default: {}
      t.datetime :occurred_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :audit_logs, :occurred_at
    add_index :audit_logs, [ :event_type, :occurred_at ]
    add_check_constraint :audit_logs, <<~SQL, name: "audit_logs_event_type"
      event_type IN (
        'ADMIN_LOGIN_SUCCEEDED', 'ADMIN_LOGGED_OUT', 'ADMIN_ACCESS_EXCHANGED',
        'QUESTION_CREATED', 'QUESTION_UPDATED', 'QUESTION_DELETED',
        'CONFIDENCE_MULTIPLIER_UPDATED', 'ACCESS_REQUEST_APPROVED', 'ACCESS_REQUEST_REJECTED',
        'MANAGEMENT_ACCESS_REVOKED', 'OPERATOR_ACCESS_GRANTED', 'OPERATOR_ACCESS_REVOKED'
      )
    SQL
  end
end
