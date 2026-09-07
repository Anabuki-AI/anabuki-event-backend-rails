class CreateRailsApiSchema < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pgcrypto"

    create_table :users do |t|
      t.string :user_name, null: false
      t.string :email, null: false
      t.string :password_digest, null: false
      t.timestamps
    end
    add_index :users, :email, unique: true
    add_index :users, :user_name

    create_table :admin_identities, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :email, null: false
      t.string :google_sub, null: false
      t.boolean :admin_enabled, null: false, default: false
      t.uuid :granted_by
      t.datetime :granted_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :admin_identities, :email, unique: true
    add_index :admin_identities, :google_sub, unique: true
    add_foreign_key :admin_identities, :admin_identities, column: :granted_by, on_delete: :nullify

    create_table :admin_device_sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :admin_identity, null: false, type: :uuid, foreign_key: true
      t.binary :device_id_hash, null: false
      t.binary :session_key_hash, null: false
      t.string :email, null: false
      t.string :google_sub, null: false
      t.string :access_source, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :admin_device_sessions, :device_id_hash, unique: true
    add_index :admin_device_sessions, :session_key_hash, unique: true
    add_index :admin_device_sessions, :expires_at
    add_check_constraint :admin_device_sessions, "access_source IN ('APPLICANT', 'MANAGEMENT_ACCESS', 'ENVIRONMENT_ACCESS')", name: "admin_device_sessions_source"

    create_table :admin_access_requests do |t|
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
    add_foreign_key :admin_access_requests, :admin_device_sessions, column: :applicant_session_id
    add_foreign_key :admin_access_requests, :admin_identities, column: :approved_by_identity_id, on_delete: :nullify
    add_foreign_key :admin_access_requests, :admin_identities, column: :rejected_by_identity_id, on_delete: :nullify
    add_index :admin_access_requests, :applicant_session_id, unique: true, where: "status = 'PENDING'", name: "pending_request_per_session"
    add_index :admin_access_requests, :expires_at, where: "status = 'PENDING'"
    add_check_constraint :admin_access_requests, "status IN ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED')", name: "admin_access_requests_status"

    create_table :admin_oauth_states do |t|
      t.binary :state_hash, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :admin_oauth_states, :state_hash, unique: true
    add_index :admin_oauth_states, :expires_at
  end
end
