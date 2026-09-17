class AddFinishedElapsedSecondsToQuizSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :quiz_sessions, :finished_elapsed_seconds, :integer
    add_check_constraint(
      :quiz_sessions,
      "finished_elapsed_seconds IS NULL OR finished_elapsed_seconds >= 0",
      name: "quiz_sessions_finished_elapsed_seconds_non_negative"
    )
  end
end
