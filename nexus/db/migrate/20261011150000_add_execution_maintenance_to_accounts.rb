class AddExecutionMaintenanceToAccounts < ActiveRecord::Migration[8.2]
  def change
    add_column :accounts, :maintenance_started_at, :datetime
  end
end
