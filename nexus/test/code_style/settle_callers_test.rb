require "test_helper"

# THE ONE RESOLUTION ENGINE has one guard ladder so its callers can never
# disagree about what a resolution is allowed to do — which only holds
# while the set of callers is KNOWN. Every one of them hands `content`
# across the same seam. Keep every caller visible here so changing the
# accepted content shape cannot leave one submitting an incompatible value.
#
# A grep count, not prose. Adding a caller means adding it here, which is
# the moment to ask whether it obeys the ladder.
class SettleCallersTest < ActiveSupport::TestCase
  CALLERS = {
    # The person's door: an await's resolution on the member plane.
    "app/controllers/agent_api/v1/workspaces/agent_loops/tasks/resolutions_controller.rb" => 1,
    # The executor plane's commit: three lock-free fences, then this one call — its `content` is the
    # request body's, read verbatim.
    "app/services/executors/commit.rb" => 1,
    # The append envelope's atomic `resolve[]` arm.
    "app/services/agent_loops/tasks/append.rb" => 1,
    # Nexus settling its own graph-writing kernel tools — compose, task,
    # ask — through one seam: the text is always a String the adapter built.
    "app/services/agent_loops/kernel_tool.rb" => 1,
    # The memory family, settling its own kernel tool the same way.
    # CHECKED: every one of its six verbs reaches this through one
    # `settle` whose `content` is built from strings — a read's text, a
    # rendered listing, joined grep lines, or a joined refusal code — so
    # the grammar's String arm is the only one it can take. The second
    # call settles an overdue mutation with timeout: true and no content.
    "app/services/agent_loops/memory/run.rb" => 2,
    # History reads hand bounded JSON text or a built refusal String to the
    # same parser, deadline and terminal-state guards; trusted skips only
    # the executor claim token, never the resolution ladder.
    "app/services/agent_loops/conversation_history/run.rb" => 1,
    # The deadline, which wins over any late answer.
    "app/services/agent_loops/parks/timeout_sweep.rb" => 1,
    # Approval decisions project an overdue hold first. Like the sweep,
    # both are timeout-only callers and submit no result content.
    "app/services/agent_loops/tasks/approve.rb" => 1,
    "app/services/agent_loops/tasks/deny.rb" => 1,
    # The child-reply relay's await path: a waited spawn's kernel-held await settled TRUSTED with
    # the child's reply text — a String the converger adopted — under one transaction with the
    # turn's relay marker.
    "app/services/agent_loops/spawn/relay.rb" => 1,
    # An observer settles its kernel-held await with stored result text
    # and structure. Settle still enforces deadlines and content bounds;
    # an unstorable observation becomes an explicit failed task.
    "app/services/agent_loops/task_waits.rb" => 1,
  }.freeze

  test "every caller of the one resolution engine is accounted for" do
    found = Hash.new(0)
    Dir.glob(Rails.root.join("{app,lib}/**/*.rb")).each do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      next if relative.end_with?("parks/settle.rb")

      count = File.read(path).scan(/(?:Parks::)?Settle\.call\(/).length
      found[relative] = count if count.positive?
    end

    assert_equal CALLERS, found,
      "the resolution engine's callers changed. Every one passes `content` " \
        "across the same seam and must obey the same guard ladder — add it " \
        "to CALLERS once you have checked that it does."
  end
end
