require "rails_helper"
require Rails.root.join("db/operator_migrate/20260917000002_remove_operator_access_requests")

RSpec.describe RemoveOperatorAccessRequests do
  let(:connection) { Operator::ApplicationRecord.connection }

  before do
    connection.drop_table(:operator_access_requests, if_exists: true)
    Operator::DeviceSession.delete_all
    Operator::Identity.delete_all
  end

  after do
    connection.drop_table(:operator_access_requests, if_exists: true)
    Operator::DeviceSession.delete_all
    Operator::Identity.delete_all
  end

  it "removes the legacy session foreign key so an operator identity can be destroyed" do
    identity = Operator::Identity.create!(email: "operator@example.com", google_sub: "operator-subject")
    session = Operator::DeviceSession.create!(
      operator_identity: identity,
      device_id_hash: Digest::SHA256.digest("device"),
      session_key_hash: Digest::SHA256.digest("session"),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: "APPLICANT",
      expires_at: 1.hour.from_now,
      last_seen_at: Time.current
    )
    create_legacy_access_requests_table(session)

    migrate_up

    expect(connection.data_source_exists?(:operator_access_requests)).to be(false)
    expect { identity.destroy! }.to change(Operator::DeviceSession, :count).from(1).to(0)
  end

  it "is irreversible because access-request records are removed" do
    expect { described_class.new.exec_migration(connection, :down) }
      .to raise_error(ActiveRecord::IrreversibleMigration, /Operator access-request records are permanently removed/)
  end

  private

  def migrate_up
    described_class.new.exec_migration(connection, :up)
  end

  def create_legacy_access_requests_table(session)
    connection.create_table :operator_access_requests, id: :uuid, default: -> { "gen_random_uuid()" } do |table|
      table.string :email, null: false
      table.string :google_sub, null: false
      table.string :status, null: false, default: "PENDING"
      table.datetime :expires_at, null: false
      table.uuid :applicant_session_id
      table.timestamps
    end
    connection.add_foreign_key :operator_access_requests, :operator_device_sessions, column: :applicant_session_id
    connection.execute <<~SQL
      INSERT INTO operator_access_requests (
        id, email, google_sub, status, expires_at, applicant_session_id, created_at, updated_at
      ) VALUES (
        gen_random_uuid(), 'operator@example.com', 'operator-subject', 'PENDING',
        CURRENT_TIMESTAMP + INTERVAL '1 hour', #{connection.quote(session.id)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end
end
