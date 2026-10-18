class AddCostLimitToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :cost_limit, :decimal, precision: 38, scale: 18
  end
end
