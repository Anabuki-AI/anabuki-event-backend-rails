class CreateQuizEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :quiz_events do |t|
      t.string :status, null: false
      t.jsonb :confidence_multipliers, null: false, default: {}
      t.datetime :finished_at
      t.timestamps
    end
    add_check_constraint :quiz_events, "status IN ('ACTIVE', 'FINISHED')", name: "quiz_events_status"

    create_table :quiz_event_questions do |t|
      t.references :quiz_event, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :source_question_id, null: false
      t.integer :position, null: false
      t.string :status, null: false
      t.string :question_text, null: false
      t.string :choice_a, null: false
      t.string :choice_b, null: false
      t.string :choice_c, null: false
      t.string :choice_d, null: false
      t.string :correct_answer, null: false
      t.string :image_url, limit: 2048
      t.integer :base_points, null: false, default: 100
      t.timestamps
    end
    add_index :quiz_event_questions, [ :quiz_event_id, :position ], unique: true
    add_index :quiz_event_questions, [ :quiz_event_id, :status ]
    add_check_constraint :quiz_event_questions, "position > 0", name: "quiz_event_questions_position_positive"
    add_check_constraint :quiz_event_questions, "status IN ('PENDING', 'PUBLISHED', 'CLOSED', 'REVEALED')", name: "quiz_event_questions_status"
    add_check_constraint :quiz_event_questions, "correct_answer IN ('A', 'B', 'C', 'D')", name: "quiz_event_questions_correct_answer"
    add_check_constraint :quiz_event_questions, "base_points > 0", name: "quiz_event_questions_base_points_positive"

    create_table :quiz_answers do |t|
      t.references :participant, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :quiz_event_question, null: false, foreign_key: { on_delete: :cascade }
      t.string :answer, null: false
      t.string :confidence_level, null: false
      t.decimal :multiplier_snapshot, precision: 3, scale: 2, null: false
      t.boolean :is_correct, null: false
      t.decimal :score, precision: 10, scale: 2, null: false
      t.timestamps
    end
    add_index :quiz_answers, [ :participant_id, :quiz_event_question_id ], unique: true
    add_check_constraint :quiz_answers, "answer IN ('A', 'B', 'C', 'D')", name: "quiz_answers_answer"
    add_check_constraint :quiz_answers, "confidence_level IN ('high', 'normal', 'low')", name: "quiz_answers_confidence_level"
    add_check_constraint :quiz_answers, "multiplier_snapshot >= 0 AND multiplier_snapshot <= 9.99", name: "quiz_answers_multiplier_snapshot_range"
    add_check_constraint :quiz_answers, "score >= 0", name: "quiz_answers_score_nonnegative"
  end
end
