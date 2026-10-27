class AddConversationTakeover < ActiveRecord::Migration[8.2]
  def change
    add_column :conversations, :taken_over_at, :datetime
    add_column :conversations, :taken_over_by_public_id, :uuid
    add_column :inputs, :source_released_at, :datetime
    add_column :turns, :source_released_at, :datetime
    remove_index :conversations, name: "index_conversations_on_parent_and_spawn_label",
      column: [:parent_conversation_id, :spawn_label], unique: true, where: "spawn_label IS NOT NULL"
    add_index :conversations, [:parent_conversation_id, :spawn_label], unique: true,
      name: "index_conversations_on_parent_and_spawn_label",
      where: "spawn_label IS NOT NULL AND taken_over_at IS NULL"
  end
end
