class AddAnsweringStartedAtToQuizSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :quiz_sessions, :answering_started_at, :datetime
  end
end
