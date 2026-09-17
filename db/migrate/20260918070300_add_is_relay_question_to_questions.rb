class AddIsRelayQuestionToQuestions < ActiveRecord::Migration[7.1]
  def change
    add_column :questions, :is_relay_question, :boolean, null: false, default: false
  end
end
