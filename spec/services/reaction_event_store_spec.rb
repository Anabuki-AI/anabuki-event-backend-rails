require "rails_helper"

RSpec.describe ReactionEventStore do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    described_class.clear!
    example.run
    described_class.clear!
  end

  it "accepts only the projector emoji allowlist and rate limits one session" do
    event = described_class.record(session_id: "session-a", reaction: "👏")

    expect(event).to have_attributes(reaction: "👏")
    expect(described_class.record(session_id: "session-a", reaction: "🎉")).to be_nil
    expect(described_class.record(session_id: "session-b", reaction: "🎉")).to have_attributes(reaction: "🎉")
    expect {
      described_class.record(session_id: "session-c", reaction: "🔥")
    }.to raise_error(described_class::InvalidReaction)
  end

  it "retains no more than 100 events and expires old events after 30 seconds" do
    now = Time.zone.parse("2026-09-30T12:00:00Z")
    101.times do |index|
      described_class.record(session_id: "session-#{index}", reaction: "👏", at: now)
    end

    expect(described_class.events_since(since: now - 1.second, now:)).to have_attributes(length: 100)

    travel_to(now + 31.seconds) do
      expect(described_class.events_since(since: now - 1.minute)).to eq([])
    end
  end
end
