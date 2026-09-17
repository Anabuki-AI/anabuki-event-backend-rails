require "rails_helper"

RSpec.describe Operator::Identity, type: :model do
  let(:email) { "operator@example.com" }

  it "stores operator emails encrypted and transparently decrypts them" do
    identity = described_class.create!(email: "  #{email.upcase}  ", google_sub: "operator-subject")
    session = Operator::DeviceSession.create!(
      operator_identity: identity,
      device_id_hash: Digest::SHA256.digest("device"),
      session_key_hash: Digest::SHA256.digest("session"),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: "APPLICANT",
      expires_at: 20.minutes.from_now,
      last_seen_at: Time.current
    )

    identity_raw_email = raw_email("operator_identities", identity.id)
    session_raw_email = raw_email("operator_device_sessions", session.id)

    expect(identity.email).to eq(email)
    expect(identity.reload.email).to eq(email)
    expect(session.reload.email).to eq(email)
    expect(identity_raw_email).not_to include(email)
    expect(session_raw_email).not_to include(email)
    expect(identity_raw_email).not_to eq(email)
    expect(session_raw_email).not_to eq(email)
  end

  it "uses deterministic encryption for normalized Google email lookup" do
    identity = described_class.create!(email:, google_sub: "operator-subject")
    raw_before = raw_email("operator_identities", identity.id)

    expect(described_class.find_by(email: email)).to eq(identity)

    identity.update!(email: email)
    expect(raw_email("operator_identities", identity.id)).to eq(raw_before)
  end

  it "keeps the deterministic email unique index" do
    described_class.create!(email:, google_sub: "operator-subject")
    email_index = described_class.connection.indexes(:operator_identities).find do |index|
      index.columns == [ "email" ]
    end

    expect(email_index).to be_present
    expect(email_index.unique).to be(true)
    expect { described_class.create!(email:, google_sub: "another-subject") }
      .to raise_error(ActiveRecord::RecordInvalid, /Email has already been taken/)

    duplicate = described_class.new(email:, google_sub: "database-duplicate-subject")
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  private

  def raw_email(table, id)
    connection = described_class.connection
    connection.select_value(
      "SELECT email FROM #{table} WHERE id = #{connection.quote(id)}"
    )
  end
end
