class AddClosingPhaseToQuizSessions < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :quiz_sessions, name: "quiz_sessions_phase"
    add_check_constraint :quiz_sessions,
      "phase IS NULL OR phase IN ('answering', 'closing', 'closed', 'revealed')",
      name: "quiz_sessions_phase"
  end
end
