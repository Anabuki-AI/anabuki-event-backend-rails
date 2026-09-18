require "rails_helper"
require "timeout"

RSpec.describe "question management and quiz progression locking", type: :model do
  # Threads must see committed setup and separate real PostgreSQL transactions.
  self.use_transactional_tests = false

  before do
    @session = QuizSession.current
    @question = Question.create!(position: 1, question_text: "Question", choice_a: "A", choice_b: "B", choice_c: "C", choice_d: "D", correct_answer: "A")
    @participant = Participant.create!(display_name: "Player", gender: "no_answer", age_group: "20s", student_type: "not_student", agreed_terms: true)
  end

  after do
    @thread&.join
    ParticipantQuizConfidenceSelection.where(participant: @participant).delete_all
    @session&.delete
    @question&.destroy!
    @participant&.destroy!
  end

  [ :update, :destroy ].each do |operation|
    it "serializes #{operation} behind publication and confidence selection" do
      pid_queue = Queue.new
      @session.with_lock do
        @session.start!
        @thread = Thread.new do
          ApplicationRecord.connection_pool.with_connection do |connection|
            pid_queue << connection.select_value("SELECT pg_backend_pid()")
            begin
              candidate = Question.find(@question.id)
              operation == :update ? candidate.update!(correct_answer: "B") : candidate.destroy!
              :unexpected_success
            rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => error
              error.class
            end
          end
        end
        pid = pid_queue.pop
        # Wait for a real lock wait, not a timing-dependent sleep/race.
        Timeout.timeout(5) do
          loop do
            ApplicationRecord.connection.execute("SELECT pg_stat_clear_snapshot()")
            break if ApplicationRecord.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}") == "Lock"

            sleep 0.01
          end
        end
        @session.confirm_confidence_level!(participant: @participant, question_id: @question.id, confidence_level: "low")
      end

      expected_error = operation == :update ? ActiveRecord::RecordInvalid : ActiveRecord::RecordNotDestroyed
      expect(@thread.value).to eq(expected_error)
      expect(@question.reload.correct_answer).to eq("A")
      expect(ParticipantQuizConfidenceSelection.find_by!(participant: @participant).eliminated_choice).not_to eq("A")
    end
  end
end
