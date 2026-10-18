class IndexUsageRecordsForConversationExport < ActiveRecord::Migration[8.1]
  def change
    add_index :usage_records, [:account_id, :conversation_public_id, :id],
      where: "conversation_public_id IS NOT NULL", name: "index_usage_records_on_conversation_history"
  end
end
