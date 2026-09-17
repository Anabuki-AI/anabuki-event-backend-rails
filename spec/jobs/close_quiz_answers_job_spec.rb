require "rails_helper"

RSpec.describe CloseQuizAnswersJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  after { travel_back }

  it "finalizes only the matching closing phase after the ten-second delay" do
    question = Question.create!(
      position: 1,
      question_text: "Question 1",
      choice_a: "choice A",
      choice_b: "choice B",
      choice_c: "choice C",
      choice_d: "choice D",
      correct_answer: "A"
    )
    session = QuizSession.current
    allow(described_class).to receive(:set).and_return(instance_double(ActiveJob::ConfiguredJob, perform_later: true))

    travel_to Time.zone.parse("2026-09-20 10:00:00") do
      session.start!
      session.request_close!
    end
    closing_started_at = session.reload.phase_started_at

    travel_to Time.zone.parse("2026-09-20 10:00:10") do
      described_class.perform_now(question.id, closing_started_at.iso8601(6))
    end

    expect(session.reload.phase).to eq("closed")
  end
end
