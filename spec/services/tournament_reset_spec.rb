require "rails_helper"

RSpec.describe TournamentReset do
  it "rejects a nil actor before starting a reset transaction" do
    expect {
      described_class.call!(actor: nil, confirmation: "RESET")
    }.to raise_error(
      TournamentReset::InvalidActor,
      "tournament reset actor with email and google_sub is required"
    )

    expect(AuditLog.where(event_type: described_class::EVENT_TYPE)).to be_empty
  end

  it "rolls every destructive mutation back when the durable audit write fails" do
    question = Question.create!(
      position: 1,
      question_text: "Question",
      choice_a: "A",
      choice_b: "B",
      choice_c: "C",
      choice_d: "D",
      correct_answer: "A"
    )
    participant = Participant.create!(
      display_name: "Player",
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
    participant_session = ParticipantSession.create!(
      participant:,
      token_hash: Digest::SHA256.digest(SecureRandom.urlsafe_base64(32, false)),
      expires_at: 1.hour.from_now
    )
    ParticipantReaction.create!(participant:, participant_session:, reaction: "👍", reacted_at: Time.current)
    ParticipantQuizConfidenceSelection.create!(
      participant:,
      question:,
      confidence_level: "normal",
      locked_at: Time.current
    )
    ParticipantAnswer.create!(participant:, question:, choice: "A", confidence_level: "normal", awarded_points: 100)
    quiz_session = QuizSession.current
    quiz_session.start!
    quiz_session.reveal!
    before_session = quiz_session.reload.attributes
    actor = Data.define(:email, :google_sub).new("operator@example.com", "operator-sub")
    allow(AuditLogRecorder).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "audit insert failed")

    expect {
      described_class.call!(actor:, confirmation: "RESET")
    }.to raise_error(ActiveRecord::StatementInvalid, "audit insert failed")

    expect(Participant.count).to eq(1)
    expect(ParticipantSession.count).to eq(1)
    expect(ParticipantReaction.count).to eq(1)
    expect(ParticipantAnswer.count).to eq(1)
    expect(ParticipantQuizConfidenceSelection.count).to eq(1)
    expect(question.reload.revealed_at).to be_present
    expect(quiz_session.reload.attributes).to eq(before_session)
    expect(AuditLog.where(event_type: described_class::EVENT_TYPE)).to be_empty
  end
end
