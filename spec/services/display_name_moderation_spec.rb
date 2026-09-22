require "rails_helper"

RSpec.describe DisplayNameModeration do
  let(:config) { DisplayNameModerationConfig.new }
  let(:transport) { instance_double(DisplayNameModerationTransport) }
  let(:logger) { instance_double(ActiveSupport::Logger, warn: nil) }
  subject(:moderation) { described_class.new(config:, transport:, logger:) }

  # nil means "leave unset" so that the config falls back to its defaults.
  def moderation_env(overrides = {})
    {
      "OPENROUTER_API_KEY" => "test-key",
      "OPENROUTER_API_URL" => nil,
      "OPENROUTER_MODEL" => nil,
      "DISPLAY_NAME_MODERATION_THRESHOLD" => nil,
      "DISPLAY_NAME_MODERATION_FAIL_CLOSED" => nil
    }.merge(overrides)
  end

  def response_body(probability)
    JSON.generate(
      "model" => "jev-1.13.0",
      "answers" => {
        "inappropriate_display_name" => { "type" => "noul", "noul" => probability }
      }
    )
  end

  it "skips evaluation entirely when no API key is configured" do
    allow(transport).to receive(:request)

    with_env(moderation_env("OPENROUTER_API_KEY" => nil)) do
      expect(moderation.inappropriate?("主催者_公式アカウント")).to be(false)
      expect(transport).not_to have_received(:request)
    end
  end

  it "sends the candidate name with the moderation rubric and flags high-probability names" do
    captured = nil
    allow(transport).to receive(:request) do |method:, url:, headers:, json:|
      captured = { method:, url:, headers:, json: }
      DisplayNameModerationTransport::Response.new(200, response_body(0.86))
    end

    with_env(moderation_env) do
      expect(moderation.inappropriate?("主催者_公式アカウント")).to be(true)
    end

    expect(captured[:method]).to eq(:post)
    expect(captured[:url]).to eq("https://openrouter.ai/api/alpha/decisions")
    expect(captured[:json]["model"]).to eq("~typesafe/jev-latest")
    expect(captured[:headers]["Authorization"]).to eq("Bearer test-key")
    expect(captured[:json]["state"]).to include("主催者_公式アカウント")
    question = captured[:json]["questions"].fetch("inappropriate_display_name")
    expect(question["type"]).to eq("noul")
    expect(question["instructions"]).to include("なりすまし")
  end

  it "permits ordinary names below the threshold" do
    allow(transport).to receive(:request)
      .and_return(DisplayNameModerationTransport::Response.new(200, response_body(0.03)))

    with_env(moderation_env) do
      expect(moderation.inappropriate?("たろう")).to be(false)
    end
  end

  it "honours a custom threshold" do
    allow(transport).to receive(:request)
      .and_return(DisplayNameModerationTransport::Response.new(200, response_body(0.86)))

    with_env(moderation_env("DISPLAY_NAME_MODERATION_THRESHOLD" => "0.9")) do
      expect(moderation.inappropriate?("境界線上の名前")).to be(false)
    end
  end

  it "fails open and logs a warning when the provider cannot be reached" do
    allow(transport).to receive(:request).and_raise(DisplayNameModerationTransport::Error, "Net::ReadTimeout")

    with_env(moderation_env) do
      expect(moderation.inappropriate?("なんでも")).to be(false)
    end

    expect(logger).to have_received(:warn).with(/display-name-moderation/)
  end

  it "fails closed when DISPLAY_NAME_MODERATION_FAIL_CLOSED is set" do
    allow(transport).to receive(:request).and_raise(DisplayNameModerationTransport::Error, "SocketError")

    with_env(moderation_env("DISPLAY_NAME_MODERATION_FAIL_CLOSED" => "true")) do
      expect(moderation.inappropriate?("なんでも")).to be(true)
    end
  end

  it "treats a non-2xx response as an unreachable provider" do
    allow(transport).to receive(:request)
      .and_return(DisplayNameModerationTransport::Response.new(503, "unavailable"))

    with_env(moderation_env) do
      expect(moderation.inappropriate?("なんでも")).to be(false)
    end
  end

  it "treats a malformed response body as an unreachable provider" do
    allow(transport).to receive(:request)
      .and_return(DisplayNameModerationTransport::Response.new(200, "not json"))

    with_env(moderation_env) do
      expect(moderation.inappropriate?("なんでも")).to be(false)
    end
  end
end
