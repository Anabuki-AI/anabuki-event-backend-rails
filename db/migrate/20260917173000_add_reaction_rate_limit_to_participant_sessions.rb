class AddReactionRateLimitToParticipantSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :participant_sessions, :last_reaction_at, :datetime
  end
end
