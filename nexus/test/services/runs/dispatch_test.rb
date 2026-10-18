require "test_helper"

# The kernel's own executors are handed a task through the one Dispatch — the
# registry's job for the tool, a plain `perform_later`, which under `enqueue_after_transaction_commit` (the 8.2
# default) waits for the scheduling transaction to land — the task is not
# parked before then, so an early hop would find nothing to run.
class Runs::DispatchTest < ActiveJob::TestCase
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "a dispatch inside the scheduling transaction enqueues once it commits" do
    run = seed(tool("a", "read_file", "input" => { "path" => "a" }))
    node = run.tasks.first
    # An authored step may not name a kernel tool (`reserved_tool_name`);
    # the row is re-labelled below the door, since only its name and id
    # reach the dispatch — the pin is the enqueue's timing, not the row.
    Task.where(id: node.id).update_all(tool_name: "wait")
    node.reload

    ApplicationRecord.transaction do
      Runs::Dispatch.after_commit(node)
      # an enqueue inside the transaction is a wakeup waiting to be lost
      assert_no_enqueued_jobs only: Runs::WaitToolJob
    end
    assert_enqueued_with(job: Runs::WaitToolJob, args: [node.id])
  end
end
