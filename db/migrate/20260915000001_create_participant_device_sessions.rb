class CreateParticipantDeviceSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :participant_device_sessions do |t|
      t.references :participant_identity, null: false, foreign_key: true
      t.binary :device_id_hash, null: false
      t.binary :session_key_hash, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :participant_device_sessions, :device_id_hash, unique: true, where: "revoked_at IS NULL", name: "active_participant_session_per_device"
    add_index :participant_device_sessions, :participant_identity_id, unique: true, where: "revoked_at IS NULL", name: "active_participant_session_per_identity"
    add_index :participant_device_sessions, :session_key_hash, unique: true
    add_index :participant_device_sessions, :expires_at
  end
end
