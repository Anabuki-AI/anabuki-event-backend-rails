class CreateQuizSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :quiz_sessions do |t|
      # Single-row guarantee: exactly one row may carry singleton = true.
      t.boolean :singleton, null: false, default: true
      t.string :status, null: false, default: "waiting"
      t.references :current_question, foreign_key: { to_table: :questions }
      t.string :phase
      t.timestamps
    end

    add_index :quiz_sessions, :singleton, unique: true
    add_check_constraint :quiz_sessions, "status IN ('waiting', 'in_progress', 'finished')", name: "quiz_sessions_status"
    add_check_constraint :quiz_sessions, "phase IS NULL OR phase IN ('answering', 'closed', 'revealed')", name: "quiz_sessions_phase"
  end
end
