require "rails_helper"

RSpec.describe AdminAuthConfig, type: :service do
  it "accepts only exact public origins" do
    with_env("PUBLIC_BASE_URL" => "https://event.example", "ADMIN_FRONTEND_URL" => "https://event.example/admin") do
      config = described_class.new

      expect(config.allowed_origin?("https://event.example")).to be(true)
      expect(config.allowed_origin?("https://attacker.example")).to be(false)
      expect(config.allowed_origin?("http://event.example")).to be(false)
      expect(config.allowed_origin?("https://event.example/unexpected-path")).to be(false)
      expect(config.allowed_origin?("https://user@event.example")).to be(false)
      expect(config.allowed_origin?("https://event.example?unexpected=query")).to be(false)
      expect(config.allowed_origin?("https://event.example#fragment")).to be(false)
    end
  end
end
