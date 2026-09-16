class AddWaitingHeartbeatToParticipantSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :participant_sessions, :waiting_heartbeat_at, :datetime
    add_index :participant_sessions, [ :waiting_heartbeat_at, :participant_id ],
      where: "revoked_at IS NULL", name: "active_waiting_participant_sessions"
  end
end
