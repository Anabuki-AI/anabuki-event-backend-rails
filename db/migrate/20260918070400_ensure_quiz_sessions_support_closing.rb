# A previously deployed relay migration shared version 20260918070000 with
# AddClosingPhaseToQuizSessions. Its ledger entry cannot tell us which ran.
# Keep published versions intact and reconcile the invariant in a new version.
class EnsureQuizSessionsSupportClosing < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :quiz_sessions, name: "quiz_sessions_phase", if_exists: true
    add_check_constraint :quiz_sessions,
      "phase IS NULL OR phase IN ('answering', 'closing', 'closed', 'revealed')",
      name: "quiz_sessions_phase"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "The historical 20260918070000 migration is ambiguous; retain the closing constraint"
  end
end
