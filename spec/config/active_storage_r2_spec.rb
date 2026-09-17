require "rails_helper"
require "erb"
require "yaml"

RSpec.describe "Cloudflare R2 Active Storage configuration" do
  it "builds an S3 service from the R2 environment variables" do
    names = %w[R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_REGION R2_BUCKET]
    previous = names.to_h { |name| [ name, ENV[name] ] }
    ENV.update(
      "R2_ENDPOINT" => "https://account-id.r2.cloudflarestorage.com",
      "R2_ACCESS_KEY_ID" => "test-access-key",
      "R2_SECRET_ACCESS_KEY" => "test-secret-key",
      "R2_REGION" => "auto",
      "R2_BUCKET" => "anabuki-event-images"
    )

    rendered = ERB.new(Rails.root.join("config/storage.yml").read).result
    config = YAML.safe_load(rendered).fetch("r2")
    service = ActiveStorage::Service.configure(:r2, "r2" => config)

    expect(service).to be_a(ActiveStorage::Service::S3Service)
    expect(service.bucket.name).to eq("anabuki-event-images")
    expect(service.client.client.config.endpoint.to_s).to eq("https://account-id.r2.cloudflarestorage.com")
  ensure
    previous&.each do |name, value|
      value.nil? ? ENV.delete(name) : ENV[name] = value
    end
  end
end
