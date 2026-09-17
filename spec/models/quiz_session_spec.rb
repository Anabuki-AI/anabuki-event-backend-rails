require "rails_helper"

RSpec.describe QuizSession do
  include ActiveSupport::Testing::TimeHelpers

  after { travel_back }

  def create_question(position:)
    Question.create!(
      position:,
      question_text: "Question #{position}",
      choice_a: "choice A",
      choice_b: "choice B",
      choice_c: "choice C",
      choice_d: "choice D",
      correct_answer: "A"
    )
  end

  it "stamps phase_started_at on every phase transition" do
    create_question(position: 1)
    second = create_question(position: 2)
    session = described_class.current

    travel_to Time.zone.parse("2026-09-20 10:00:00") do
      session.start!
    end
    expect(session.reload.phase_started_at).to eq(Time.zone.parse("2026-09-20 10:00:00"))

    travel_to Time.zone.parse("2026-09-20 10:00:30") do
      session.publish_next!
    end
    expect(session.reload.phase_started_at).to eq(Time.zone.parse("2026-09-20 10:00:30"))

    travel_to Time.zone.parse("2026-09-20 10:01:00") do
      session.close!
    end
    expect(session.reload.phase_started_at).to eq(Time.zone.parse("2026-09-20 10:01:00"))

    travel_to Time.zone.parse("2026-09-20 10:01:10") do
      session.reveal!
    end
    expect(session.reload.phase_started_at).to eq(Time.zone.parse("2026-09-20 10:01:10"))

    travel_to Time.zone.parse("2026-09-20 10:02:00") do
      session.finish!
    end
    expect(session.reload.phase_started_at).to eq(Time.zone.parse("2026-09-20 10:02:00"))
  end

  it "marks the current question revealed and clears that history on reset" do
    question = create_question(position: 1)
    session = described_class.current
    session.start!

    session.reveal!
    expect(question.reload.revealed_at).to be_present

    session.reset!
    expect(question.reload.revealed_at).to be_nil
  end

  it "stamps phase_started_at when reset! forces the session back to waiting" do
    create_question(position: 1)
    session = described_class.current
    session.start!

    travel_to 1.hour.from_now do
      session.reset!
    end

    expect(session.reload.phase_started_at).to be_within(1.second).of(1.hour.from_now)
  end

  it "leaves phase_started_at nil until the first transition" do
    expect(described_class.current.phase_started_at).to be_nil
  end
end
