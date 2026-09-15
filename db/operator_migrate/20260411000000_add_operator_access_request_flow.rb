class AddOperatorAccessRequestFlow < ActiveRecord::Migration[8.0]
  def up
    # Managers approved by an admin keep operator manager access across logins,
    # mirroring AdminIdentity#admin_enabled.
    add_column :operator_identities, :manager_enabled, :boolean, null: false, default: false
    add_column :operator_identities, :granted_by, :uuid
    add_column :operator_identities, :granted_at, :datetime
    add_column :operator_identities, :revoked_at, :datetime
    # granted_by stores the promoting admin's AdminIdentity uuid (primary DB),
    # so it deliberately carries no FK into operator tables.

    # Applicant sessions join the flow alongside MANAGER sessions.
    execute "ALTER TABLE operator_device_sessions DROP CONSTRAINT operator_device_sessions_source"
    add_check_constraint :operator_device_sessions, "access_source IN ('MANAGER', 'APPLICANT')", name: "operator_device_sessions_source"

    create_table :operator_access_requests, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :email, null: false
      t.string :google_sub, null: false
      t.string :status, null: false, default: "PENDING"
      t.string :approved_by_email
      t.string :approved_by_google_sub
      t.uuid :approved_by_identity_id
      t.datetime :approved_at
      t.string :rejected_by_email
      t.string :rejected_by_google_sub
      t.uuid :rejected_by_identity_id
      t.datetime :rejected_at
      t.datetime :expires_at, null: false
      t.uuid :applicant_session_id
      t.binary :applicant_device_id_hash
      t.binary :applicant_session_key_hash
      t.datetime :cancelled_at
      t.string :cancellation_reason
      t.timestamps
    end
    # The approver is an AdminIdentity living in the primary database, so the
    # *_by_identity_id columns deliberately carry no FK into operator tables.
    add_foreign_key :operator_access_requests, :operator_device_sessions, column: :applicant_session_id
    add_index :operator_access_requests, :applicant_session_id, unique: true, where: "status = 'PENDING'", name: "pending_request_per_session"
    add_index :operator_access_requests, :expires_at, where: "status = 'PENDING'"
    add_check_constraint :operator_access_requests, "status IN ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED')", name: "operator_access_requests_status"
  end

  def down
    drop_table :operator_access_requests

    execute "ALTER TABLE operator_device_sessions DROP CONSTRAINT operator_device_sessions_source"
    add_check_constraint :operator_device_sessions, "access_source IN ('MANAGER')", name: "operator_device_sessions_source"

    remove_column :operator_identities, :revoked_at
    remove_column :operator_identities, :granted_at
    remove_column :operator_identities, :granted_by
    remove_column :operator_identities, :manager_enabled
  end
end
