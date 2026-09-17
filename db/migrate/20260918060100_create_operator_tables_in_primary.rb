class CreateOperatorTablesInPrimary < ActiveRecord::Migration[8.1]
  def change
    create_table :operator_identities, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # Active Record Encryption stores deterministic ciphertext in this text
      # column. The model exposes the decrypted email transparently.
      t.text :email, null: false
      t.string :google_sub, null: false
      t.boolean :manager_enabled, null: false, default: false
      t.uuid :granted_by
      t.datetime :granted_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :operator_identities, :email, unique: true
    add_index :operator_identities, :google_sub, unique: true

    create_table :operator_device_sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :operator_identity_id, null: false
      t.binary :device_id_hash, null: false
      t.binary :session_key_hash, null: false
      # This is a denormalized encrypted snapshot used to detect identity
      # changes when a device cookie is presented.
      t.text :email, null: false
      t.string :google_sub, null: false
      t.string :access_source, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_foreign_key :operator_device_sessions, :operator_identities
    add_index :operator_device_sessions, :device_id_hash, unique: true
    add_index :operator_device_sessions, :session_key_hash, unique: true
    add_index :operator_device_sessions, :expires_at
    add_check_constraint :operator_device_sessions, "access_source IN ('MANAGER', 'APPLICANT')", name: "operator_device_sessions_source"

    # The operator OAuth state ID was historically a bigint; preserve that
    # schema while keeping the hashed state itself binary and unique.
    create_table :operator_oauth_states do |t|
      t.binary :state_hash, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :operator_oauth_states, :state_hash, unique: true
    add_index :operator_oauth_states, :expires_at
  end
end
