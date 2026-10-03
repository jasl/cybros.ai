class AddExpectedSteeringLoopToConversationInputs < ActiveRecord::Migration[8.2]
  def change
    add_column :conversation_inputs, :expected_steering_loop_public_id, :uuid
  end
end
