class RetireAgentRunnerAssignments < ActiveRecord::Migration[8.2]
  def up
    # Retain task/history identities while fencing every old private address.
    # These registrations cannot be widened into a different assignment scope.
    execute <<~SQL
      UPDATE executors SET status = 'revoked', credential_epoch = credential_epoch + 1,
        assignment_scope = NULL, presence_connection_id = NULL, presence_server_id = NULL,
        connected_at = NULL, updated_at = CURRENT_TIMESTAMP
      WHERE assignment_scope = 'agent_private'
    SQL
    execute <<~SQL
      UPDATE device_authorizations SET status = 'invalidated', selected_assignment_scope = NULL,
        updated_at = CURRENT_TIMESTAMP
      WHERE status IN ('pending', 'connected') AND
        (assignment_agent_public_id IS NOT NULL OR
         (agent_identifier IS NOT NULL AND registration_identifier IS NOT NULL))
    SQL
    remove_reference :executors, :assignment_agent, foreign_key: { to_table: :users }
    remove_column :device_authorizations, :assignment_agent_public_id
    remove_column :executors, :served_tools
    remove_column :executors, :served_documents
    remove_column :executors, :environment
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retired private registrations cannot regain their old credentials or assignment"
  end
end
