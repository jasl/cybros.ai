class AddCallbackProvenanceToConversationInputsAndTurns < ActiveRecord::Migration[8.1]
  def change
    add_column :conversation_inputs, :callback_result, :jsonb
    add_column :conversation_turns, :input_public_id, :uuid
    add_column :conversation_turns, :callback_sources, :jsonb, default: [], null: false
  end
end
