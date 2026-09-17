class AddRevealedAtToQuestions < ActiveRecord::Migration[8.1]
  def change
    add_column :questions, :revealed_at, :datetime
    add_index :questions, :revealed_at
  end
end
