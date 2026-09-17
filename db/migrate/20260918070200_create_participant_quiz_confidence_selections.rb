class CreateParticipantQuizConfidenceSelections < ActiveRecord::Migration[8.1]
  def change
    create_table :participant_quiz_confidence_selections, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :participant, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :question, null: false, foreign_key: { on_delete: :cascade }
      t.string :confidence_level, null: false
      t.string :eliminated_choice
      t.datetime :locked_at, null: false
      t.timestamps
    end

    add_index :participant_quiz_confidence_selections,
      [ :participant_id, :question_id ],
      unique: true,
      name: "index_quiz_confidence_selections_on_participant_and_question"
    add_check_constraint :participant_quiz_confidence_selections,
      "confidence_level IN ('high', 'normal', 'low')",
      name: "participant_quiz_confidence_selections_level"
    add_check_constraint :participant_quiz_confidence_selections,
      "eliminated_choice IS NULL OR eliminated_choice IN ('A', 'B', 'C', 'D')",
      name: "participant_quiz_confidence_selections_eliminated_choice"
  end
end
