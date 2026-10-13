class AddAgentPrivateRunnerAssignment < ActiveRecord::Migration[8.1]
  def change
    add_reference :task_executors, :assignment_agent, foreign_key: { to_table: :users, on_delete: :restrict }
    add_column :device_authorizations, :assignment_agent_public_id, :uuid
  end
end
