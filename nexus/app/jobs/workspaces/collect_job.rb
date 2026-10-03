# Daily physical collection of eligible Workspace tombstones.
# Level-triggered: collection re-derives eligibility from current rows, so a
# duplicate or stale wake is harmless.
class Workspaces::CollectJob < ApplicationJob
  BUDGET = 1_000

  def perform(after_deleted_at = nil, after_id = 0)
    result = Workspaces::Collect.call(
      budget: BUDGET, after_deleted_at: after_deleted_at, after_id: after_id
    )

    self.class.perform_later(*result.cursor) if result.more?
  end
end
