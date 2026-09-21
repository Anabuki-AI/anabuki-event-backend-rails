class RemovePersistedParticipantReactions < ActiveRecord::Migration[8.1]
  def up
    drop_table :participant_reactions, if_exists: true
    remove_column :participant_sessions, :last_reaction_at, if_exists: true
  end

  def down
    add_column :participant_sessions, :last_reaction_at, :datetime unless column_exists?(:participant_sessions, :last_reaction_at)

    return if table_exists?(:participant_reactions)

    create_table :participant_reactions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :participant, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :participant_session, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :reaction, null: false
      t.datetime :reacted_at, null: false
      t.timestamps
    end

    add_index :participant_reactions, [ :reacted_at, :reaction ]
    add_check_constraint :participant_reactions,
      "reaction IN ('👏', '🎉', '🙌', '😂', '😢', '😲', '👍', '❤️')",
      name: "participant_reactions_reaction"
  end
end
