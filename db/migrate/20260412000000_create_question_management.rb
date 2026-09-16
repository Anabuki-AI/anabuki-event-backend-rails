class CreateQuestionManagement < ActiveRecord::Migration[8.1]
  def change
    create_table :questions do |t|
      t.integer :position, null: false
      t.string :question_text, null: false
      t.string :choice_a, null: false
      t.string :choice_b, null: false
      t.string :choice_c, null: false
      t.string :choice_d, null: false
      t.string :correct_answer, null: false
      t.string :image_url, limit: 2048
      t.timestamps
    end
    add_index :questions, :position, unique: true
    add_check_constraint :questions, "position > 0", name: "questions_position_positive"
    add_check_constraint :questions, "correct_answer IN ('A', 'B', 'C', 'D')", name: "questions_correct_answer"

    create_table :confidence_multipliers do |t|
      t.string :level, null: false
      t.decimal :confidence_multiplier, precision: 3, scale: 2, null: false
      t.timestamps
    end
    add_index :confidence_multipliers, :level, unique: true
    add_check_constraint :confidence_multipliers, "level IN ('high', 'normal', 'low')", name: "confidence_multipliers_level"
    add_check_constraint :confidence_multipliers, "confidence_multiplier >= 0 AND confidence_multiplier <= 9.99", name: "confidence_multipliers_range"
  end
end
