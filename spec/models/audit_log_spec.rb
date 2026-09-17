require "rails_helper"

RSpec.describe AuditLog, type: :model do
  it "accepts a minimal entry from the closed event type enum" do
    entry = AuditLog.create!(event_type: "ADMIN_LOGGED_OUT", occurred_at: Time.current)
    expect(entry).to be_persisted
    expect(entry.detail).to eq({})
    expect(entry.admin_identity_id).to be_nil
  end

  it "rejects unknown event types and non-scalar detail values" do
    expect(AuditLog.new(event_type: "NOT_A_TYPE", occurred_at: Time.current)).not_to be_valid
    expect(AuditLog.new(event_type: "ADMIN_LOGGED_OUT")).not_to be_valid

    unsafe = AuditLog.new(event_type: "ADMIN_LOGGED_OUT", occurred_at: Time.current, detail: { "blob" => %w[not scalar] })
    expect(unsafe).not_to be_valid
    expect(unsafe.errors[:detail]).to be_present
  end
end
