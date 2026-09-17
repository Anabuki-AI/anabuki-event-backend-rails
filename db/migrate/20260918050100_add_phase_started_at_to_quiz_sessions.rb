class AddPhaseStartedAtToQuizSessions < ActiveRecord::Migration[8.1]
  def change
    # Timestamp of the most recent phase transition, so operators (and later
    # participants) can compute "time remaining" for a per-question timer.
    # NULL until the quiz has gone through its first transition.
    add_column :quiz_sessions, :phase_started_at, :datetime
  end
end
