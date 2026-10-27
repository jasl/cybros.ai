class AddConversationCommunication < ActiveRecord::Migration[8.2]
  def change
    add_column :inputs, :communication_kind, :string
    add_column :turns, :communication_kind, :string
  end
end
