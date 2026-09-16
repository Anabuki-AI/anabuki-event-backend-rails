class CreateParticipantReactions < ActiveRecord::Migration[8.1]
  def change
    create_table :participant_reactions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :participant, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :participant_session, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :reaction, null: false
      t.datetime :reacted_at, null: false
      t.timestamps
    end

    add_index :participant_reactions, [ :reaction, :reacted_at ]
  end
end
