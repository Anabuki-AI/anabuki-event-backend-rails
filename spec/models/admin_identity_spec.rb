# frozen_string_literal: true

require "rails_helper"

RSpec.describe AdminIdentity, type: :model do
  it "normalizes email before validation and persistence" do
    identity = described_class.create!(email: " Applicant@Example.COM ", google_sub: "google-subject")

    expect(identity.email).to eq("applicant@example.com")
  end

  it "requires a Google subject" do
    identity = described_class.new(email: "applicant@example.com", google_sub: nil)

    expect(identity).to be_invalid
    expect(identity.errors[:google_sub]).to include("can't be blank")
  end

  it "rejects a second identity with the same normalized email" do
    described_class.create!(email: "applicant@example.com", google_sub: "first-subject")
    duplicate = described_class.new(email: " Applicant@Example.COM ", google_sub: "second-subject")

    expect(duplicate).to be_invalid
    expect(duplicate.errors[:email]).to include("has already been taken")
  end

  it "rejects a Google subject already linked to another identity" do
    described_class.create!(email: "first@example.com", google_sub: "same-subject")
    duplicate = described_class.new(email: "second@example.com", google_sub: "same-subject")

    expect(duplicate).to be_invalid
    expect(duplicate.errors[:google_sub]).to include("has already been taken")
  end
end
