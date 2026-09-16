require "rails_helper"

RSpec.describe ParticipantSession do
  describe ".active_participant_count" do
    it "counts distinct participants with an unexpired, non-revoked heartbeat in the active window" do
      observed_at = Time.utc(2026, 9, 30, 12, 0, 0)
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

  def create_participant_session(participant, heartbeat_at:, expires_at: nil, revoked_at: nil)
    ParticipantSession.create!(
      participant:,
      token_hash: Digest::SHA256.digest(SecureRandom.hex),
      waiting_heartbeat_at: heartbeat_at,
      expires_at: expires_at || (heartbeat_at ? heartbeat_at + 1.day : 1.day.from_now),
      revoked_at:
    )
  end
end
