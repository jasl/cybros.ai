class AddExecutionDetailsRetentionDaysToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :execution_details_retention_days, :integer, default: 90
  end
end
