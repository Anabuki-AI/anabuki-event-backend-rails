require "rails_helper"

RSpec.describe AuditLog, type: :model do
  it "accepts a minimal entry from the closed event type enum" do
    entry = AuditLog.create!(event_type: "ADMIN_LOGGED_OUT", occurred_at: Time.current)
    expect(entry).to be_persisted
    expect(entry.detail).to eq({})
    expect(entry.admin_identity_id).to be_nil
  end

  it "requires durable operation metadata with ordered timestamps for tournament resets" do
    started_at = Time.current
    entry = AuditLog.create!(
      event_type: "TOURNAMENT_RESET",
      actor_email: "operator@example.com",
      actor_google_sub: "operator-sub",
      operation_id: SecureRandom.uuid,
      operation_started_at: started_at,
      operation_completed_at: started_at + 1.second,
      occurred_at: started_at + 1.second,
      detail: { "participantsDeleted" => 2 }
    )
    expect(entry).to be_persisted

    missing = AuditLog.new(event_type: "TOURNAMENT_RESET", occurred_at: Time.current)
    expect(missing).not_to be_valid
    expect(missing.errors).to include(
      :operation_id, :operation_started_at, :operation_completed_at,
      :actor_email, :actor_google_sub
    )

    reversed = entry.dup
    reversed.operation_id = SecureRandom.uuid
    reversed.operation_completed_at = reversed.operation_started_at - 1.second
    expect(reversed).not_to be_valid
    expect(reversed.errors[:operation_completed_at]).to be_present
  end

  it "enforces tournament reset actor snapshots at the database layer" do
    now = Time.current

    expect {
      AuditLog.transaction(requires_new: true) do
        AuditLog.insert_all!([ {
          event_type: "TOURNAMENT_RESET",
          actor_email: nil,
          actor_google_sub: nil,
          operation_id: SecureRandom.uuid,
          operation_started_at: now,
          operation_completed_at: now,
          occurred_at: now,
          detail: {}
        } ])
      end
    }.to raise_error(ActiveRecord::StatementInvalid, /audit_logs_tournament_reset_operation/)
  end

  it "rejects unknown event types and non-scalar detail values" do
    expect(AuditLog.new(event_type: "NOT_A_TYPE", occurred_at: Time.current)).not_to be_valid
    expect(AuditLog.new(event_type: "ADMIN_LOGGED_OUT")).not_to be_valid

    unsafe = AuditLog.new(event_type: "ADMIN_LOGGED_OUT", occurred_at: Time.current, detail: { "blob" => %w[not scalar] })
    expect(unsafe).not_to be_valid
    expect(unsafe.errors[:detail]).to be_present
  end
end
