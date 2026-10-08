class WidenConversationInputDeliveryMode < ActiveRecord::Migration[8.2]
  def up
    change_column :conversation_inputs, :delivery_mode, :string, limit: 16, default: "queue", null: false
  end

  def down
    change_column :conversation_inputs, :delivery_mode, :string, limit: 8, default: "queue", null: false
  end
end
