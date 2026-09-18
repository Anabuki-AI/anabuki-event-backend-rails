require "rails_helper"
require "timeout"

RSpec.describe "Tournament reset participant-write locking" do
  self.use_transactional_tests = false

  Actor = Data.define(:email, :google_sub)

  before do
    clear_reset_data
    QuizSession.current
  end

  after do
    clear_reset_data
  end

  it "completes alongside registration without a participant/session table deadlock" do
    registration_ready = Queue.new
    finish_registration = Queue.new
    registration_result = Queue.new

    registration_thread = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        connection.transaction do
          participant = Participant.create!(participant_attributes("Registering player"))
          registration_ready << true
          finish_registration.pop
          ParticipantSession.create!(
            participant:,
            token_hash: Digest::SHA256.digest(SecureRandom.urlsafe_base64(32, false)),
            expires_at: 1.hour.from_now
          )
        end
      end
      registration_result << nil
    rescue StandardError => error
      registration_result << error
    end

    Timeout.timeout(5) { registration_ready.pop }
    reset_thread, reset_pid, reset_result = start_reset_thread
    wait_until_lock_wait(reset_pid)
    finish_registration << true

    expect(thread_result(registration_thread, registration_result)).to be_nil
    result = thread_result(reset_thread, reset_result)
    expect(result).to be_a(TournamentReset::Result)
    expect(result.affected_rows.fetch(:participants)).to eq(1)
    expect(Participant.count).to eq(0)
    expect(ParticipantSession.count).to eq(0)
  ensure
    finish_registration << true if finish_registration&.empty?
    registration_thread&.kill if registration_thread&.alive?
    reset_thread&.kill if reset_thread&.alive?
  end

  it "completes alongside a reaction using participants -> sessions -> reactions lock order" do
    participant = Participant.create!(participant_attributes("Reacting player"))
    session = ParticipantSession.create!(
      participant:,
      token_hash: Digest::SHA256.digest(SecureRandom.urlsafe_base64(32, false)),
      expires_at: 1.hour.from_now
    )
    participant_locked = Queue.new
    finish_reaction = Queue.new
    reaction_result = Queue.new

    allow_any_instance_of(Participant).to receive(:lock!).and_wrap_original do |method, *arguments|
      value = method.call(*arguments)
      participant_locked << true
      finish_reaction.pop
      value
    end

    reaction_thread = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        ParticipantSession.includes(:participant).find(session.id).record_reaction(reaction: "👍")
      end
      reaction_result << nil
    rescue StandardError => error
      reaction_result << error
    end

    Timeout.timeout(5) { participant_locked.pop }
    reset_thread, reset_pid, reset_result = start_reset_thread
    wait_until_lock_wait(reset_pid)
    finish_reaction << true

    expect(thread_result(reaction_thread, reaction_result)).to be_nil
    result = thread_result(reset_thread, reset_result)
    expect(result).to be_a(TournamentReset::Result)
    expect(result.affected_rows.fetch(:participant_reactions)).to eq(1)
    expect(Participant.count).to eq(0)
    expect(ParticipantSession.count).to eq(0)
    expect(ParticipantReaction.count).to eq(0)
  ensure
    finish_reaction << true if finish_reaction&.empty?
    reaction_thread&.kill if reaction_thread&.alive?
    reset_thread&.kill if reset_thread&.alive?
  end

  private

  def start_reset_thread
    pid_queue = Queue.new
    result_queue = Queue.new
    thread = Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        pid_queue << connection.select_value("SELECT pg_backend_pid()").to_i
        result_queue << TournamentReset.call!(
          actor: Actor.new("operator@example.com", "operator-sub"),
          confirmation: "RESET"
        )
      end
    rescue StandardError => error
      result_queue << error
    end
    [ thread, Timeout.timeout(5) { pid_queue.pop }, result_queue ]
  end

  def wait_until_lock_wait(pid)
    Timeout.timeout(5) do
      loop do
        wait_event_type = ApplicationRecord.connection.select_value(<<~SQL.squish)
          SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}
        SQL
        return if wait_event_type == "Lock"

        sleep 0.01
      end
    end
  end

  def thread_result(thread, result_queue)
    result = Timeout.timeout(10) { result_queue.pop }
    expect(thread.join(1)).to eq(thread)
    raise result if result.is_a?(Exception)

    result
  end

  def participant_attributes(display_name)
    {
      display_name:,
      gender: "no_answer",
      age_group: "20s",
      student_type: "not_student",
      agreed_terms: true
    }
  end

  def clear_reset_data
    ParticipantReaction.delete_all
    ParticipantAnswer.delete_all
    ParticipantQuizConfidenceSelection.delete_all
    ParticipantSession.delete_all
    Participant.delete_all
    QuizSession.delete_all
    AuditLog.where(event_type: TournamentReset::EVENT_TYPE).delete_all
  end
end
