class AddStoppedAtToAgentLoops < ActiveRecord::Migration[8.2]
  def change
    add_column :agent_loops, :stopped_at, :datetime
    add_index :conversation_inputs, :id, name: "index_conversation_inputs_source_frontier",
      where: "sender_agent_loop_public_id IS NOT NULL"
  end
end
