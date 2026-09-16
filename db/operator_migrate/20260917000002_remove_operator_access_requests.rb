class RemoveOperatorAccessRequests < ActiveRecord::Migration[8.1]
  def up
    drop_table :operator_access_requests
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Operator access-request records are permanently removed"
  end
end
