# Per-question score (配点). Defaults to 100 to match the scoring engine's
# existing BASE_SCORE constant (see ParticipantAnswer), so existing rows and
# any question created without specifying points keep today's behavior.
class AddPointsToQuestions < ActiveRecord::Migration[8.1]
  def change
    add_column :questions, :points, :integer, null: false, default: 100
    add_check_constraint :questions, "points > 0", name: "questions_points_positive"
  end
end
