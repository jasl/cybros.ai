class AddMemoryContextToConversationsAndVariants < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :memory_context, :jsonb
    add_column :conversation_turn_variants, :memory_context, :jsonb
  end
end
