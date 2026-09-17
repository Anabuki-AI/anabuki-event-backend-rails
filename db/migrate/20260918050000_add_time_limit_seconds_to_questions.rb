class AddTimeLimitSecondsToQuestions < ActiveRecord::Migration[8.1]
  def change
    # NULL means "no time limit" (existing questions keep their current
    # untimed behavior; operators opt individual questions into a timer).
    add_column :questions, :time_limit_seconds, :integer
  end
end
