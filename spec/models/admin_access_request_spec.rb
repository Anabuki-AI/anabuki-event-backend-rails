# frozen_string_literal: true

require "rails_helper"
require "digest"

RSpec.describe AdminAccessRequest, type: :model do
  def applicant_identity
    @applicant_identity ||= AdminIdentity.create!(email: "applicant@example.com", google_sub: "applicant-sub")
  end

  def applicant_session
    @applicant_session ||= AdminDeviceSession.create!(
      admin_identity: applicant_identity,
      device_id_hash: Digest::SHA256.digest("device"),
      session_key_hash: Digest::SHA256.digest("session"),
      email: applicant_identity.email,
      google_sub: applicant_identity.google_sub,
      access_source: "APPLICANT",
      expires_at: 20.minutes.from_now,
      last_seen_at: Time.current
    )
  end

  def pending_attributes
    {
      email: applicant_identity.email,
      google_sub: applicant_identity.google_sub,
      status: "PENDING",
      expires_at: applicant_session.expires_at,
      applicant_session:,
      applicant_device_id_hash: applicant_session.device_id_hash,
      applicant_session_key_hash: applicant_session.session_key_hash
    }
  end

  it "binds a pending request to an applicant session and both 32-byte cookie digests" do
    request = described_class.new(**pending_attributes)

    expect(request).to be_valid
    expect(request).to be_pending
    expect(request.applicant_session).to eq(applicant_session)

    request.assign_attributes(
      applicant_session: nil,
      applicant_device_id_hash: nil,
      applicant_session_key_hash: nil
    )
    expect(request).to be_invalid
    expect(request.errors[:applicant_session]).to include("can't be blank")
    expect(request.errors[:applicant_device_id_hash]).to include("can't be blank")
    expect(request.errors[:applicant_session_key_hash]).to include("can't be blank")
  end

  it "rejects non-32-byte binding digests for a pending request" do
    request = described_class.new(**pending_attributes.merge(
      applicant_device_id_hash: "d" * 31,
      applicant_session_key_hash: "s" * 33
    ))

    expect(request).to be_invalid
    expect(request.errors[:applicant_device_id_hash]).to include("is the wrong length (should be 32 characters)")
    expect(request.errors[:applicant_session_key_hash]).to include("is the wrong length (should be 32 characters)")
  end

  it "requires cancellation metadata for CANCELLED while retaining the uppercase persisted status" do
    request = described_class.new(**pending_attributes.merge(
      status: "CANCELLED",
      applicant_session: nil,
      applicant_device_id_hash: nil,
      applicant_session_key_hash: nil,
      cancelled_at: nil,
      cancellation_reason: nil
    ))

    expect(request).to be_invalid
    expect(request.errors[:cancelled_at]).to include("can't be blank")
    expect(request.errors[:cancellation_reason]).to include("can't be blank")

    request.assign_attributes(cancelled_at: Time.current, cancellation_reason: "APPLICANT_LOGGED_OUT")
    expect(request).to be_valid
    expect(request).to be_cancelled
    expect(request.status).to eq("cancelled")
    expect(described_class.statuses).to include("cancelled" => "CANCELLED")
  end
end
