require "rails_helper"

RSpec.describe ParticipantReaction do
  let(:participant) do
    Participant.create!(
      display_name: "Quiz Player",
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
  end
  let(:participant_session) do
    ParticipantSession.create!(
      participant:,
      token_hash: Digest::SHA256.digest(SecureRandom.hex),
      expires_at: 1.day.from_now
    )
  end

  it "accepts exactly the reactions displayed in the waiting UI" do
    expect(described_class::REACTIONS).to eq(%w[👏 🎉 🙌 😂 😢 😲 👍 ❤️])

    described_class::REACTIONS.each do |reaction|
      event = described_class.new(participant:, participant_session:, reaction:, reacted_at: Time.current)
      expect(event).to be_valid
    end
  end

  it "rejects an unknown reaction" do
    event = described_class.new(participant:, participant_session:, reaction: "🔥", reacted_at: Time.current)

    expect(event).not_to be_valid
    expect(event.errors.of_kind?(:reaction, :inclusion)).to be(true)
  end

  it "requires a server reaction time and matching participant session" do
    other_participant = Participant.create!(
      display_name: "Other Player",
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
    event = described_class.new(
      participant: other_participant,
      participant_session:,
      reaction: "👏",
      reacted_at: nil
    )

    expect(event).not_to be_valid
    expect(event.errors.of_kind?(:reacted_at, :blank)).to be(true)
    expect(event.errors[:participant]).to include("must match participant session")
  end
end
