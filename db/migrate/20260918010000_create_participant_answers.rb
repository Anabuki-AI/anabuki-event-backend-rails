class CreateParticipantAnswers < ActiveRecord::Migration[8.1]
  def change
    create_table :participant_answers, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :participant, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :question, null: false, foreign_key: { on_delete: :cascade }
      t.string :choice, null: false
      t.string :confidence_level, null: false
      t.integer :awarded_points, null: false, default: 0
      t.timestamps
    end

    add_index :participant_answers, [ :participant_id, :question_id ], unique: true, name: "index_participant_answers_on_participant_and_question"
    add_check_constraint :participant_answers, "choice IN ('A', 'B', 'C', 'D')", name: "participant_answers_choice"
    add_check_constraint :participant_answers, "confidence_level IN ('high', 'normal', 'low')", name: "participant_answers_confidence_level"
  end
end
