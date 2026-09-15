class CreateParticipantIdentities < ActiveRecord::Migration[8.0]
  def change
    create_table :participant_identities do |t|
      t.uuid :uuid, null: false
      t.string :user_name, null: false
      t.string :gender, null: false
      t.string :age_group, null: false
      t.string :school
      t.string :department
      t.boolean :agreed_terms, null: false
      t.timestamps
    end

    add_index :participant_identities, :uuid, unique: true
    add_index :participant_identities, :user_name, unique: true
    add_check_constraint :participant_identities, "char_length(user_name) BETWEEN 3 AND 20", name: "participant_user_name_length"
    add_check_constraint :participant_identities, "gender IN ('男性', '女性', '回答しない')", name: "participant_gender"
    add_check_constraint :participant_identities, "age_group IN ('10代', '20代', '30代', '40代', '50代', '60代以上')", name: "participant_age_group"
    add_check_constraint :participant_identities, "school IS NULL OR char_length(school) <= 100", name: "participant_school_length"
    add_check_constraint :participant_identities, "department IS NULL OR char_length(department) <= 100", name: "participant_department_length"
    add_check_constraint :participant_identities, "agreed_terms IS TRUE", name: "participant_terms_accepted"
  end
end
