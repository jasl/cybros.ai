class AddMemoryLimitsAndConversationReach < ActiveRecord::Migration[8.2]
  def change
    add_column :users, :memory_context_limit, :jsonb
    add_column :users, :conversation_reach, :string
    add_column :conversations, :conversation_reach, :string, default: "workspace", null: false
    add_column :agent_runs, :memory_context, :jsonb
    add_column :agent_runs, :conversation_reach, :string, default: "workspace", null: false
    add_reference :memory_documents, :speaker, foreign_key: true
    remove_index :memory_documents, [:user_id, :name], unique: true,
      where: "user_id IS NOT NULL", name: "index_memory_documents_user_identity"
    add_index :memory_documents, [:user_id, :name], unique: true,
      where: "user_id IS NOT NULL AND speaker_id IS NULL", name: "index_memory_documents_user_identity"
    add_index :memory_documents, [:user_id, :speaker_id, :name], unique: true,
      where: "speaker_id IS NOT NULL", name: "index_memory_documents_speaker_identity"
  end
end
