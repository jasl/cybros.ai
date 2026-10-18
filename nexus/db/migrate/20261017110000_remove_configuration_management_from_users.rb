class RemoveConfigurationManagementFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :configuration_management, :string, null: false, default: "application"
  end
end
