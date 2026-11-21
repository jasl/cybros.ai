class IndexLiveTasksByRun < ActiveRecord::Migration[8.2]
  disable_ddl_transaction!

  def change
    add_index :tasks, [:run_id, :status], name: "index_tasks_on_live_run_status",
      where: "status = ANY (ARRAY['queued', 'needs_approval', 'running', 'dispatched', 'awaiting_input'])",
      algorithm: :concurrently
    # The full (run_id, status) index also serves unrestricted Run lookups.
    # A separate run_id index can win a live probe by filtering its entire history.
    remove_index :tasks, :run_id, name: "index_tasks_on_run_id", algorithm: :concurrently
  end
end
