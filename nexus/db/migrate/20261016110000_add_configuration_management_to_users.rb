class AddConfigurationManagementToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :configuration_management, :string, null: false, default: "application"
  end
end
