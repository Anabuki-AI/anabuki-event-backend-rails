# frozen_string_literal: true

require "rails_helper"
require "digest"

RSpec.describe AdminDeviceSession, type: :model do
  def identity
    @identity ||= AdminIdentity.create!(email: "applicant@example.com", google_sub: "applicant-sub")
  end

  def valid_attributes
    {
      admin_identity: identity,
      device_id_hash: Digest::SHA256.digest("device"),
      session_key_hash: Digest::SHA256.digest("session"),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: "APPLICANT",
      expires_at: 20.minutes.from_now,
      last_seen_at: Time.current
    }
  end

  it "belongs to its identity, owns its access requests, and exposes the applicant enum predicate" do
    session = described_class.create!(**valid_attributes)
    access_request = AdminAccessRequest.create!(
      email: identity.email,
      google_sub: identity.google_sub,
      status: "PENDING",
      expires_at: session.expires_at,
      applicant_session: session,
      applicant_device_id_hash: session.device_id_hash,
      applicant_session_key_hash: session.session_key_hash
    )

    expect(session.admin_identity).to eq(identity)
    expect(session.admin_access_requests).to contain_exactly(access_request)
    expect(session).to be_applicant
    expect(session).not_to be_management_access
    expect(session).not_to be_environment_access
  end

  it "requires both persisted cookie digests to be exactly 32 bytes" do
    session = described_class.new(**valid_attributes.merge(
      device_id_hash: "d" * 31,
      session_key_hash: "s" * 33
    ))

    expect(session).to be_invalid
    expect(session.errors[:device_id_hash]).to include("is the wrong length (should be 32 characters)")
    expect(session.errors[:session_key_hash]).to include("is the wrong length (should be 32 characters)")
  end

  it "requires a valid access-source enum and an associated identity" do
    session = described_class.new(**valid_attributes.merge(admin_identity: nil, access_source: "UNKNOWN"))

    expect(session).to be_invalid
    expect(session.errors[:admin_identity]).to include("must exist")
    expect(session.errors[:access_source]).to include("is not included in the list")
  end
end
