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

  it "also accepts origins listed in ADDITIONAL_ALLOWED_ORIGINS" do
    with_env(
      "PUBLIC_BASE_URL" => "https://event.example",
      "ADMIN_FRONTEND_URL" => "https://event.example/admin",
      "ADDITIONAL_ALLOWED_ORIGINS" => " http://192.168.1.50:3000 ,http://192.168.1.51:3000"
    ) do
      config = described_class.new

      expect(config.allowed_origin?("http://192.168.1.50:3000")).to be(true)
      expect(config.allowed_origin?("http://192.168.1.51:3000")).to be(true)
      expect(config.allowed_origin?("http://192.168.1.52:3000")).to be(false)
      # Still exact-origin matching: trailing whitespace and path are not host/port.
      expect(config.allowed_origin?("http://192.168.1.50:3000/admin")).to be(false)
    end
  end

  it "ignores a blank ADDITIONAL_ALLOWED_ORIGINS" do
    with_env("PUBLIC_BASE_URL" => "https://event.example", "ADDITIONAL_ALLOWED_ORIGINS" => "") do
      config = described_class.new

      expect(config.allowed_origin?("https://event.example")).to be(true)
      expect(config.allowed_origin?("https://attacker.example")).to be(false)
    end
  end
end
