class AddMessagingPolicyToWorkspaces < ActiveRecord::Migration[8.2]
  def change
    add_column :workspaces, :messaging_policy, :jsonb, null: false, default: { agents: [] }
  end
end
