require "rails_helper"
require "set"

RSpec.describe AdminAuthConfig, type: :service do
  let(:configured_env) do
    {
      "PUBLIC_BASE_URL" => "https://event.example",
      "ADMIN_FRONTEND_URL" => "https://admin.example:8443/console",
      "GOOGLE_OAUTH_CALLBACK_URL" => "https://event.example/api/auth/google/callback",
      "GOOGLE_CLIENT_ID" => "test-client.apps.googleusercontent.com",
      "GOOGLE_CLIENT_SECRET" => "test-client-secret"
    }
  end

  it "is configured only when credentials and HTTP(S) callback and frontend URLs are present" do
    with_env(configured_env) do
      expect(described_class.new.oauth_configured?).to be(true)

      with_env("GOOGLE_CLIENT_SECRET" => "") do
        expect(described_class.new.oauth_configured?).to be(false)
      end
      with_env("GOOGLE_OAUTH_CALLBACK_URL" => "mailto:ops@example.com") do
        expect(described_class.new.oauth_configured?).to be(false)
      end
      with_env("ADMIN_FRONTEND_URL" => "https:///admin") do
        expect(described_class.new.oauth_configured?).to be(false)
      end
    end
  end

  it "allows only configured origins with exactly matching scheme, host, and port" do
    with_env(configured_env) do
      config = described_class.new

      expect(config.allowed_origin?("https://event.example")).to be(true)
      expect(config.allowed_origin?("https://admin.example:8443")).to be(true)
      expect(config.allowed_origin?("https://event.example:443")).to be(true)
      expect(config.allowed_origin?("http://event.example")).to be(false)
      expect(config.allowed_origin?("https://event.example:8443")).to be(false)
      expect(config.allowed_origin?("https://attacker.example")).to be(false)
    end
  end

  it "rejects malformed values and URLs that are not serialized HTTP Origin values" do
    with_env(configured_env) do
      config = described_class.new

      expect(config.allowed_origin?("")).to be(false)
      expect(config.allowed_origin?("null")).to be(false)
      expect(config.allowed_origin?("https://event.example:bad-port")).to be(false)
      expect(config.allowed_origin?("https://event.example/unexpected-path")).to be(false)
      expect(config.allowed_origin?("https://user@event.example")).to be(false)
      expect(config.allowed_origin?("https://event.example?unexpected=query")).to be(false)
      expect(config.allowed_origin?("https://event.example#fragment")).to be(false)
    end
  end

  it "normalizes and deduplicates only valid allowlisted email addresses" do
    with_env(
      "ADMIN_EMAIL_ALLOWLIST" => " Environment@Example.COM, second@example.com, invalid-address, space @example.com, environment@example.com "
    ) do
      expect(described_class.new.environment_access_emails).to eq(
        Set["environment@example.com", "second@example.com"]
      )
    end
  end
end
