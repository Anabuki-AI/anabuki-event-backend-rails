# frozen_string_literal: true

require "rails_helper"
require "digest"

RSpec.describe AdminOauthState, type: :model do
  it "requires a 32-byte state digest and an expiry" do
    state = described_class.new(state_hash: "x" * 31, expires_at: nil)

    expect(state).to be_invalid
    expect(state.errors[:state_hash]).to include("is the wrong length (should be 32 characters)")
    expect(state.errors[:expires_at]).to include("can't be blank")
  end

  it "accepts a 32-byte state digest with an expiry" do
    state = described_class.new(
      state_hash: Digest::SHA256.digest("oauth-state"),
      expires_at: 10.minutes.from_now
    )

    expect(state).to be_valid
  end

  it "does not permit a second row for the same state digest" do
    digest = Digest::SHA256.digest("oauth-state")
    described_class.create!(state_hash: digest, expires_at: 10.minutes.from_now)
    duplicate = described_class.new(state_hash: digest, expires_at: 10.minutes.from_now)

    expect(duplicate).to be_invalid
    expect(duplicate.errors[:state_hash]).to include("has already been taken")
  end
end
