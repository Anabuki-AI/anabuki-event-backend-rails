require "rails_helper"

RSpec.describe ParticipantSession do
  describe ".active_participant_count" do
    let(:observed_at) { Time.utc(2026, 9, 30, 12, 0, 0) }

    it "counts distinct participants with an unexpired, non-revoked heartbeat in the active window" do
      first_participant = create_participant
      second_participant = create_participant

      create_participant_session(first_participant, heartbeat_at: observed_at - 1.second)
      create_participant_session(first_participant, heartbeat_at: observed_at - 2.seconds)
      create_participant_session(second_participant, heartbeat_at: observed_at - 75.seconds)
      create_participant_session(create_participant, heartbeat_at: observed_at - 76.seconds)
      create_participant_session(create_participant, heartbeat_at: observed_at - 1.second, revoked_at: observed_at - 1.second)
      create_participant_session(create_participant, heartbeat_at: observed_at - 1.second, expires_at: observed_at - 1.second)
      create_participant_session(create_participant, heartbeat_at: nil)

      expect(described_class.active_participant_count(observed_at:)).to eq(2)
    end
  end

  describe "#record_reaction" do
    let(:participant) { create_participant }
    let(:participant_session) { create_participant_session(participant, heartbeat_at: nil, expires_at: 1.day.from_now) }

    it "serializes a session's cooldown while allowing a separate session to react" do
      expect(participant_session).to receive(:lock!).twice.and_call_original

      first_event = nil
      expect {
        first_event = participant_session.record_reaction(reaction: "👏")
      }.to change(ParticipantReaction, :count).by(1)
      expect(first_event).to have_attributes(participant:, participant_session:, reaction: "👏")
      expect(participant_session.reload.last_reaction_at).to eq(first_event.reacted_at)

      limited_event = nil
      expect {
        limited_event = participant_session.record_reaction(reaction: "🎉")
      }.not_to change(ParticipantReaction, :count)
      expect(limited_event).to be_nil

      other_session = create_participant_session(participant, heartbeat_at: nil, expires_at: 1.day.from_now)
      expect(other_session.record_reaction(reaction: "🎉")).to be_a(ParticipantReaction)
    end
  end

  private

  def create_participant
    Participant.create!(
      display_name: "Quiz Player",
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
  end

  def create_participant_session(participant, heartbeat_at:, expires_at: observed_at + 1.day, revoked_at: nil)
    ParticipantSession.create!(
      participant:,
      token_hash: Digest::SHA256.digest(SecureRandom.hex),
      waiting_heartbeat_at: heartbeat_at,
      expires_at:,
      revoked_at:
    )
  end
end
