class AddUniqueDisplayNameIndexToParticipants < ActiveRecord::Migration[8.1]
  def change
    add_index :participants, "lower(display_name)", unique: true, name: "index_participants_on_lower_display_name"
  end
end
