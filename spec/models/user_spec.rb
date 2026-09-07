require "rails_helper"

RSpec.describe User, type: :model do
  it "hashes passwords and normalizes email" do
    user = described_class.create!(user_name: "Example", email: " USER@Example.COM ", password: "secure-password")

    expect(user.email).to eq("user@example.com")
    expect(user.authenticate("secure-password")).to be_truthy
    expect(user.password_digest).not_to eq("secure-password")
  end
end
