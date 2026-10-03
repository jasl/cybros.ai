class AddSourceWorkHintIndexes < ActiveRecord::Migration[8.2]
  def change
    add_index :conversation_inputs, [:sender_agent_loop_public_id, :id],
      name: "index_conversation_inputs_on_source_work",
      where: "sender_agent_loop_public_id IS NOT NULL"
    add_index :conversation_turns, [:sender_agent_loop_public_id, :id],
      name: "index_conversation_turns_on_source_work",
      where: "sender_agent_loop_public_id IS NOT NULL"
  end
end
