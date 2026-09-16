class AddExplanationAndTargetAudienceToQuestions < ActiveRecord::Migration[8.1]
  def change
    add_column :questions, :explanation, :string
    add_column :questions, :target_audience, :string
  end
end
