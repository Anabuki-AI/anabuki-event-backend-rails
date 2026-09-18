class AddLiveCorrectAnswerConfirmedAtToQuestions < ActiveRecord::Migration[8.1]
  def change
    # Distinguishes "the operator explicitly confirmed this relay question's
    # answer while it was live" from an untouched correct_answer that merely
    # carries whatever placeholder value the question was created/edited with.
    # Nil means unconfirmed; the frontend uses this to block reveal until the
    # operator has made an explicit choice during this live round.
    add_column :questions, :live_correct_answer_confirmed_at, :datetime, if_not_exists: true
    add_index :questions, :live_correct_answer_confirmed_at, if_not_exists: true
  end
end
