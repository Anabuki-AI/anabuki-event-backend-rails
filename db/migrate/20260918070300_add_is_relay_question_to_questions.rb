class AddIsRelayQuestionToQuestions < ActiveRecord::Migration[7.1]
  def change
    add_column :questions, :is_relay_question, :boolean, null: false, default: false, if_not_exists: true
  end
end
