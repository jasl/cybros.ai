require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class AgentLoopsLockOrderTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  # The loop plane's own converger, and the flow that pins its two new
  # ranks at once: the loop row is the graph's universal lane lock, the
  # step invocation is locked under it, and the narration cursor comes
  # LAST. Cancel runs the same three tables in the same order (its
  # in-flight terminalizations deliberately precede any narration), so the
  # ABBA those two would otherwise complete cannot exist.
  test "the loop step converger descends loop, invocation, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    agent_loop, node = create_agent_loop_step(account: account, creator: human)
    ModelInvocation.where(id: node.selected_model_invocation_id)
      .update_all(status: "failed", failure_reason_key: "probe")

    sequences = assert_ladder_order("loop step converger") do
      assert_equal 1, AgentLoops::ConvergeTerminalSteps.call[:recorded]
    end

    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[agent_loops model_invocations conversation_event_cursors]
    assert_equal "failed", agent_loop.reload.agent_loop_nodes.sole.status
  end

  # The regression shape: a pass that FAILS one ready task and MINTS another takes the event cursor
  # (ladder tail) and then reaches back down for content fragments. Narration is buffered to the end
  # of the transaction precisely so this flow cannot invert; drive it here so the guard, not
  # intuition, is what says so.
  test "a mixed schedule pass seals fragments before it ever takes the cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(parallel(tool("probe"), model("step", "prompt" => "go")), model("after"),
      workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    agent_loop = created.agent_loop
    AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: human
    ))

    sequences = assert_ladder_order("mixed schedule pass") do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end

    seen = sequences.flatten
    assert_includes seen, "content_fragments"
    assert_includes seen, "conversation_event_cursors"
    assert_equal "dispatched", agent_loop.agent_loop_nodes.find_by(node_key: "probe").status,
      "the tool parks on its runner"
    assert_equal "running", agent_loop.agent_loop_nodes.find_by(node_key: "step").status
  end

  # The await door is the first flow to lock a task row explicitly, so it
  # is driven here rather than trusted: loop, then task, then the cursor
  # its narration takes.
  test "an await resolution descends loop, task, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(ask("gate"), workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    agent_loop = created.agent_loop
    AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: human
    ))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    gate = agent_loop.agent_loop_nodes.sole.reload

    sequences = assert_ladder_order("await resolution") do
      result = AgentLoops::Parks::Settle.call(
        node: gate, claim_token: gate.resolution_token, content: "answered"
      )
      assert_predicate result, :applied?
    end

    # The content write sits between the task and the cursor, which is
    # ladder-correct; what this pins is the ORDER of the three new ranks.
    seen = sequences.flatten
    assert_operator seen.index("agent_loops"), :<, seen.index("agent_loop_nodes")
    assert_operator seen.index("agent_loop_nodes"), :<,
      seen.index("conversation_event_cursors")
  end

  # The executor claim: loop, then the one task it grants — the executor and workspace reads are
  # lock-free, so `task_executors` (ranked BEFORE `agent_loops`) never appears after the loop.
  test "the executor claim descends loop then task, never the executor row" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(tool("probe"), workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    agent_loop = created.agent_loop
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: human))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)

    sequences = assert_ladder_order("executor claim") do
      result = Executors::Claim.call(Executors::Claim::Command.new(
        agent_loop: agent_loop, task_key: "probe", executor: suite_runner
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
    end

    seen = sequences.flatten
    assert_operator seen.index("agent_loops"), :<, seen.index("agent_loop_nodes")
    assert_not_includes seen, "task_executors"
  end

  # THE HANDOFF: two transactions. The first holds the HOST row (a conversation's lane lock) for the
  # binding write and its `runner_bound` append — the cursor is the ladder's last rank — and touches
  # no loop; the second, per live loop, holds loop → task → cursor for the re-address pass.
  # `task_executors` (ranked ABOVE the host rungs) is read lock-free throughout, so it appears in
  # neither.
  test "a handoff descends host then cursor, then per loop: loop, task, cursor — two transactions" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human,
      runner_executor: suite_runner)
    seam = create_loop_backed_turn(conversation: conversation, acting_user: human)
    grown = grow(seam.agent_loop, tool("probe"))
    assert_predicate grown, :applied?
    AgentLoops::ScheduleReady.call(agent_loop_id: seam.agent_loop.id)
    assert_equal "dispatched", seam.agent_loop.agent_loop_nodes.find_by!(node_key: "probe").status
    other = connect_runner(manager: users(:owner), runner_identifier: "handoff-target",
      display_name: "Target", assignment_scope: :account_wide).executor_access_token.task_executor
    other.announce(tools: LoopAuthoringTestHelper::TEST_SERVED_TOOLS)

    sequences = assert_ladder_order("handoff") do
      result = Executors::Handoff.call(Executors::Handoff::Command.new(
        host: conversation, executor_public_id: other.public_id, acting_user: human
      ))
      assert_equal :accepted, result.outcome, result.detail.to_s
      assert_equal ["probe"], result.value.readdressed.map(&:task_key)
    end

    assert_equal 2, sequences.length, "the binding write and the pass are two transactions: #{sequences.inspect}"
    binding, pass = sequences
    assert_equal %w[conversations conversation_event_cursors], binding.uniq
    assert_not_includes binding, "agent_loops"
    assert_not_includes binding, "agent_loop_nodes"
    assert_operator pass.index("agent_loops"), :<, pass.index("agent_loop_nodes")
    assert_operator pass.index("agent_loop_nodes"), :<, pass.index("conversation_event_cursors")
    assert_not_includes pass, "conversations"
    assert_not_includes sequences.flatten, "task_executors"
  end

  test "a standalone loop's handoff holds the loop for the binding, then the loop again for the pass" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(tool("probe"), workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    agent_loop = created.agent_loop
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: human))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    other = connect_runner(manager: users(:owner), runner_identifier: "handoff-target",
      display_name: "Target", assignment_scope: :account_wide).executor_access_token.task_executor
    other.announce(tools: LoopAuthoringTestHelper::TEST_SERVED_TOOLS)

    sequences = assert_ladder_order("standalone handoff") do
      result = Executors::Handoff.call(Executors::Handoff::Command.new(
        host: agent_loop, executor_public_id: other.public_id, acting_user: human
      ))
      assert_equal :accepted, result.outcome, result.detail.to_s
    end

    assert_equal 2, sequences.length, sequences.inspect
    binding, pass = sequences
    assert_equal %w[agent_loops conversation_event_cursors], binding.uniq
    assert_equal "agent_loops", pass.first
    assert_operator pass.index("agent_loops"), :<, pass.index("agent_loop_nodes")
    assert_not_includes sequences.flatten, "task_executors"
  end

  # The executor commit: the three fences are lock-free reads before
  # Settle's loop lock; then loop, task, and the cursor its narration takes.
  test "the executor commit descends loop, task, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(tool("probe"), workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    agent_loop = created.agent_loop
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: human))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: "probe", executor: suite_runner
    ))
    assert_predicate claimed, :accepted?

    sequences = assert_ladder_order("executor commit") do
      result = Executors::Commit.call(Executors::Commit::Command.new(
        agent_loop: agent_loop, task_key: "probe", executor: suite_runner,
        claim_token: claimed.value.claim_token, content: "answered", structured_content: nil,
        result_type: nil, outcome: "completed", is_error: false, title: nil, metadata: nil
      ))
      assert_predicate result, :applied?
    end

    seen = sequences.flatten
    assert_operator seen.index("agent_loops"), :<, seen.index("agent_loop_nodes")
    assert_operator seen.index("agent_loop_nodes"), :<, seen.index("conversation_event_cursors")
    assert_not_includes seen, "task_executors"
  end

  # THE COMMIT CARRYING A `resource_link`: the linked capture is resolved and pinned `FOR KEY SHARE`
  # BETWEEN the loop lock and the node lock — `content_uploads` sits below `agent_loops` and above
  # `agent_loop_nodes`, the rung every input door already drives — and the body writer then binds it
  # under the same order.
  test "the executor commit carrying a resource_link pins the capture between the loop and the task" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(tool("probe"), workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    agent_loop = created.agent_loop
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: human))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: "probe", executor: suite_runner
    ))
    assert_predicate claimed, :accepted?
    capture = account.content_uploads.create!(
      creating_executor: suite_runner,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("lock-order-capture"), filename: "capture.png", content_type: "image/png"
      )
    )

    sequences = assert_ladder_order("executor commit with a capture") do
      result = Executors::Commit.call(Executors::Commit::Command.new(
        agent_loop: agent_loop, task_key: "probe", executor: suite_runner,
        claim_token: claimed.value.claim_token,
        content: [{ "type" => "text", "text" => "saved" },
                  { "type" => "resource_link", "uri" => "nexus://uploads/#{capture.public_id}", "name" => "capture.png" }],
        structured_content: nil, result_type: nil, outcome: "completed", is_error: false, title: nil, metadata: nil
      ))
      assert_predicate result, :applied?
    end

    seen = sequences.flatten
    assert_includes seen, "content_uploads", "the commit pins the capture it binds"
    %w[agent_loops content_uploads agent_loop_nodes content_fragments].each_cons(2) do |above, below|
      assert_operator seen.index(above), :<, seen.index(below),
        "the commit descends #{above} before #{below}: #{seen.inspect}"
    end
    assert_not_includes seen, "task_executors"
  end

  test "loop cancel terminalizes its steps before it narrates" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    agent_loop, = create_agent_loop_step(account: account, creator: human)

    sequences = assert_ladder_order("loop cancel") do
      result = AgentLoops::Stop.call(AgentLoops::Stop::Command.forced(
        agent_loop: agent_loop, acting_user: human
      ))
      assert_predicate result, :accepted?
    end

    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[agent_loops model_invocations conversation_event_cursors]
  end
end
