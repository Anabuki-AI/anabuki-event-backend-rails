class AddIsSelectedRelayQuestionToQuestions < ActiveRecord::Migration[7.1]
  def change
    add_column :questions, :is_selected_relay_question, :boolean, null: false, default: false, if_not_exists: true

    # At most one question may be the "currently selected" relay question at a
    # time. Non-relay questions must always be false (enforced in the model),
    # so this partial unique index is sufficient without a CHECK constraint.
    add_index :questions, :is_selected_relay_question, unique: true,
      where: "is_selected_relay_question = true",
      name: "index_questions_on_is_selected_relay_question_true",
      if_not_exists: true
  end
end
