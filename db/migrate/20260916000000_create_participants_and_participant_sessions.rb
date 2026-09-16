class CreateParticipantsAndParticipantSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :participants, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :display_name, null: false
      t.string :gender, null: false
      t.string :age_group, null: false
      t.string :student_type, null: false
      t.string :school, null: false, default: ""
      t.string :department, null: false, default: ""
      t.boolean :agreed_terms, null: false, default: false
      t.timestamps
    end

    create_table :participant_sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :participant, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.binary :token_hash, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :participant_sessions, :token_hash, unique: true
    add_index :participant_sessions, :expires_at
  end
end
