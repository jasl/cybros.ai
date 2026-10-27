class CreateConversationLinks < ActiveRecord::Migration[8.2]
  def change
    create_table :conversation_links do |t|
      t.uuid :public_id, null: false, default: -> { connection.database_version >= 180_000 ? "uuidv7()" : "uuid_generate_v7()" }
      t.references :account, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.references :first_conversation, null: false, foreign_key: { to_table: :conversations, on_delete: :cascade }
      t.references :first_agent, null: false, foreign_key: { to_table: :users }
      t.references :second_conversation, null: false, foreign_key: { to_table: :conversations, on_delete: :cascade }
      t.references :second_agent, null: false, foreign_key: { to_table: :users }
      t.datetime :closed_at
      t.string :close_reason
      t.timestamps
    end
    add_index :conversation_links, :public_id, unique: true
    add_index :conversation_links, [:first_conversation_id, :first_agent_id, :second_conversation_id, :second_agent_id],
      unique: true, where: "closed_at IS NULL", name: "index_conversation_links_on_active_pair"
    add_reference :inputs, :conversation_link, foreign_key: true
    add_column :turns, :conversation_link_public_id, :uuid
  end
end
