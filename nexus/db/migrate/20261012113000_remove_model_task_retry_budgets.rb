class RemoveModelTaskRetryBudgets < ActiveRecord::Migration[8.2]
  def change
    remove_column :agent_run_tasks, :retry_budget, :integer, default: 0, null: false
    remove_column :agent_run_tasks, :auto_retries_used, :integer, default: 0, null: false
  end
end
