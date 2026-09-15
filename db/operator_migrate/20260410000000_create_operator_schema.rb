class CreateOperatorSchema < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pgcrypto"

    create_table :operator_identities, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :email, null: false
      t.string :google_sub, null: false
      t.timestamps
    end
    add_index :operator_identities, :email, unique: true
    add_index :operator_identities, :google_sub, unique: true

    create_table :operator_device_sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :operator_identity, null: false, type: :uuid, foreign_key: true
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
    add_index :operator_device_sessions, :device_id_hash, unique: true
    add_index :operator_device_sessions, :session_key_hash, unique: true
    add_index :operator_device_sessions, :expires_at
    add_check_constraint :operator_device_sessions, "access_source IN ('MANAGER')", name: "operator_device_sessions_source"

    create_table :operator_oauth_states do |t|
      t.binary :state_hash, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :operator_oauth_states, :state_hash, unique: true
    add_index :operator_oauth_states, :expires_at
  end
end
