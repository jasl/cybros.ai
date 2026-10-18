module Runs
  # THE KERNEL'S OWN EXECUTORS are handed a `running` row through the
  # registry's job for the tool: one `perform_later`, which under
  # `enqueue_after_transaction_commit` (the 8.2 default) waits for the
  # scheduling transaction to land — the row is not parked before then, so an
  # early hop would find nothing to run. A row addressed outside the kernel
  # is nudged instead (`Executors::Nudge`).
  module Dispatch
    module_function

    def after_commit(node)
      if node.mcp_call?
        McpToolJob.perform_later(node.id, node.execution_generation)
      else
        Nexus::ToolRegistry.job_for(node.tool_name).perform_later(node.id)
      end
    end

    # The scheduler is the durable recovery floor for a lost enqueue or a job
    # deferred by Pause/maintenance. Already-started HTTP is never redelivered.
    def recover(run)
      run.tasks.where(status: "running", external_started_at: nil)
        .where.not(mcp_connection_public_id: nil).find_each { |node| after_commit(node) }
    end
  end
end
