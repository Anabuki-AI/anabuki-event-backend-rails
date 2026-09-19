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

  it "stamps phase_started_at on every transition and fixes the final elapsed seconds" do
    create_question(position: 1)
    second = create_question(position: 2)
    second.update!(time_limit_seconds: 30)
    session = described_class.current

    travel_to Time.zone.parse("2026-09-20 10:00:00") do
      session.start!
    end
    expect(session.reload.phase_started_at).to eq(Time.zone.parse("2026-09-20 10:00:00"))

    travel_to Time.zone.parse("2026-09-20 10:00:30") do
      session.reveal!
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
    expect(session.finished_elapsed_seconds).to eq(50)
  end

  it "clears the fixed elapsed seconds on reset" do
    create_question(position: 1)
    session = described_class.current

    travel_to Time.zone.parse("2026-09-20 10:00:00") do
      session.start!
    end
    travel_to Time.zone.parse("2026-09-20 10:00:07") do
      session.finish!
    end
    expect(session.reload.finished_elapsed_seconds).to eq(7)

    session.reset!

    expect(session.reload.finished_elapsed_seconds).to be_nil
  end

  it "starts closing immediately but finalizes the requested close only after ten seconds" do
    question = create_question(position: 1)
    session = described_class.current
    scheduled = instance_double(ActiveJob::ConfiguredJob, perform_later: true)
    allow(CloseQuizAnswersJob).to receive(:set).and_return(scheduled)

    travel_to Time.zone.parse("2026-09-20 10:00:00") do
      session.start!
      session.request_close!
    end

    expect(session.reload.phase).to eq("closing")
    expect(session.phase_started_at).to eq(Time.zone.parse("2026-09-20 10:00:00"))
    expect(scheduled).to have_received(:perform_later).with(question.id, session.phase_started_at.iso8601(6))

    travel_to Time.zone.parse("2026-09-20 10:00:09") do
      session.complete_requested_close!(question_id: question.id, closing_started_at: session.phase_started_at)
    end
    expect(session.reload.phase).to eq("closing")

    travel_to Time.zone.parse("2026-09-20 10:00:10") do
      session.complete_requested_close!(question_id: question.id, closing_started_at: session.phase_started_at)
    end
    expect(session.reload.phase).to eq("closed")
  end

  it "ignores a scheduled close that no longer matches the current question" do
    first = create_question(position: 1)
    second = create_question(position: 2)
    session = described_class.current
    allow(CloseQuizAnswersJob).to receive(:set).and_return(instance_double(ActiveJob::ConfiguredJob, perform_later: true))
    session.start!
    session.request_close!
    closing_started_at = session.reload.phase_started_at
    session.reset!
    session.start!
    session.reveal!
    session.publish_next!

    travel_to 1.minute.from_now do
      session.complete_requested_close!(question_id: first.id, closing_started_at:)
    end

    expect(session.reload).to have_attributes(current_question_id: second.id, phase: "answering")
  end

  it "does not let an expired snapshot close a newly published question" do
    create_question(position: 1)
    second = create_question(position: 2)
    session = described_class.current
    session.start!
    allow(CloseQuizAnswersJob).to receive(:set).and_return(instance_double(ActiveJob::ConfiguredJob, perform_later: true))
    session.request_close!
    stale = described_class.current
    deadline = stale.phase_started_at + 10.seconds

    travel_to(deadline, with_usec: true) do
      session.reveal!
      session.publish_next!
      stale.close_expired_answer_window!
    end

    expect(session.reload).to have_attributes(current_question_id: second.id, phase: "answering")
  end

  it "rechecks automatic expiry under lock instead of trusting an expired snapshot" do
    first = create_question(position: 1)
    first.update!(time_limit_seconds: 5)
    second = create_question(position: 2)
    second.update!(time_limit_seconds: 30)
    session = described_class.current
    session.start!
    stale = described_class.current
    deadline = session.answering_started_at + 5.seconds

    travel_to(deadline, with_usec: true) do
      session.reveal!
      session.publish_next!
      expect { stale.close! }.to raise_error(QuizSession::InvalidTransition, "Question time limit has not expired")
    end

    expect(session.reload).to have_attributes(current_question_id: second.id, phase: "answering")
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

  it "clears locked confidence selections on reset" do
    question = create_question(position: 1)
    participant = Participant.create!(
      display_name: "Player",
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
    session = described_class.current
    session.start!
    session.select_confidence_level!(participant:, question_id: question.id, confidence_level: "low")

    session.reset!

    expect(ParticipantQuizConfidenceSelection).to be_none
  end

  it "rejects Lv.1 while a relay question is live without creating a selection" do
    question = create_question(position: 1)
    question.update!(is_relay_question: true, is_selected_relay_question: true)
    participant = Participant.create!(
      display_name: "Player",
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    )
    session = described_class.current
    session.start!

    expect {
      session.select_confidence_level!(participant:, question_id: question.id, confidence_level: "low")
    }.to raise_error(QuizSession::InvalidTransition, "Lv.1 cannot be selected for a live relay question")
    expect(ParticipantQuizConfidenceSelection).to be_none
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

  it "does not retry an insert when the singleton is already materialized" do
    described_class.current
    inserts = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      inserts << payload[:sql] if payload[:sql].start_with?('INSERT INTO "quiz_sessions"')
    end

    described_class.current

    expect(inserts).to be_empty
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "serializes concurrent first access into one singleton row" do
    described_class.delete_all
    release = Queue.new
    threads = 4.times.map do
      Thread.new do
        release.pop
        described_class.current.id
      end
    end
    threads.each { release << true }

    ids = threads.map(&:value)

    expect(ids.uniq).to eq([ ids.first ])
    expect(described_class.where(singleton: true).count).to eq(1)
  end
end
