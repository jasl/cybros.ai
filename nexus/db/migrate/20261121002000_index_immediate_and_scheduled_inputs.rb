class IndexImmediateAndScheduledInputs < ActiveRecord::Migration[8.2]
  def change
    add_index :inputs, "host_type, state, COALESCE(deliver_at, created_at), id",
      name: "index_inputs_pending_due"
    remove_index :inputs, [:deliver_at, :id], name: "index_inputs_due",
      where: "deliver_at IS NOT NULL AND state = 'pending' AND host_type = 'Conversation'"
  end
end
