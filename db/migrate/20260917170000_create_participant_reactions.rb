class CreateParticipantReactions < ActiveRecord::Migration[8.1]
  def change
    create_table :participant_reactions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :participant, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :participant_session, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :reaction, null: false
      t.datetime :reacted_at, null: false
      t.timestamps
    end

    # Aggregation normally constrains a time window before grouping by reaction.
    add_index :participant_reactions, [ :reacted_at, :reaction ]
    add_check_constraint :participant_reactions,
      "reaction IN ('👏', '🎉', '🙌', '😂', '😢', '😲', '👍', '❤️')",
      name: "participant_reactions_reaction"
  end
end
