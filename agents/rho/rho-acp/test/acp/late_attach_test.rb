require "test_helper"

# WHAT A CLIENT SEES WHEN THE FOLLOW ATTACHES AFTER THE WORK MOVED.
#
# `Turn#open` answers the say, correlates the input receipt through the host
# feed and only then follows the turn, so between the two a call can start,
# a call can settle and a park can open. The daemon's first frame to a late
# follower is the SNAPSHOT — the accumulated state, not a replay of the
# frames that made it — and this file pins what the surface does with it,
# because the e2e ACP lane reads the frames and went ~1-in-3 red on exactly
# this window (2026-09-22: `no tool_call_update settled the call`, and `no
# request was held within 120 s`).
class AcpLateAttachTest < Minitest::Test
  Methods = Rho::Acp::Methods
  Update = Methods::SessionUpdate

  def setup
    @core = RhoAcpTest::CoreDouble.new
    @core.tasks[["alp_1", "k1"]] = { "tool_name" => "bash", "tool_input" => { "command" => "ls" }, "output_preview" => "a.rb\nb.rb" }
    @live = Queue.new
    @core.events["cnv_1"] = @live
  end

  def teardown
    @harness&.close
  end

  def open(policy: RhoAcpTest.permission_policy("allow"), mode: "ask")
    @harness = RhoAcpTest::AgentHarness.new(core: @core, mode: mode)
    @harness.policy = policy
    @harness.initialize_agent
    @harness.new_session(cwd: "/tmp")
    @harness
  end

  def wait_for(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  # A CALL THAT STARTED AND SETTLED INSIDE THE WINDOW: the snapshot carries
  # the task already `completed`, so the client is told about the call as a
  # `tool_call` in its final state, and — its settled-call frame having gone
  # by unseen — the completion's preview comes off the task read as the one
  # `tool_call_update` a live client got, so a late client ends on the same
  # frames a live one did: the call with its diffs, then its preview.
  def test_a_call_that_settled_before_the_follow_is_one_tool_call_in_its_final_state
    harness = open
    pending = harness.start_prompt("cnv_1", "look around")
    @live << ["snapshot", { "turn" => "trn_1", "loop" => "alp_1",
                            "tasks" => [{ "task_key" => "k1", "kind" => "tool_task", "status" => "completed" }] }]
    @live << ["turn_status", { "turn_public_id" => "trn_1", "agent_loop_public_id" => "alp_1",
                               "status" => "completed", "loop_status" => "completed" }]
    @live << ["closed", {}]
    answer = pending.wait(timeout: 5)

    assert_equal({ "stopReason" => "end_turn" }, answer)
    calls = harness.updates_of("tool_call").map { |update| update.fetch("update") }
    updates = harness.updates_of("tool_call_update").map { |update| update.fetch("update") }
    assert_equal ["alp_1:k1"], calls.map { |call| call.fetch("toolCallId") }
    assert_equal [Methods::ToolCallStatus::COMPLETED], calls.map { |call| call.fetch("status") },
      "the one frame the client gets carries the settled status"
    assert_equal [{ "toolCallId" => "alp_1:k1", "status" => Methods::ToolCallStatus::COMPLETED,
                    "content" => [{ "type" => "content", "content" => { "type" => "text", "text" => "a.rb\nb.rb" } }] }],
      updates.map { |update| update.slice("toolCallId", "status", "content") },
      "the completion a live client got, from the task read's preview"
  end

  # A PARK THAT OPENED INSIDE THE WINDOW: the snapshot carries the loop's
  # attention, and the surface asks the client from it — the permission
  # request does not depend on having seen the `attention_required` frame.
  def test_a_park_that_opened_before_the_follow_still_asks_the_client
    seen = nil
    policy = lambda do |inbound|
      seen = inbound.params
      inbound.respond("outcome" => { "outcome" => "selected", "optionId" => "allow" })
    end
    harness = open(policy: policy)
    pending = harness.start_prompt("cnv_1", "clean up")
    @live << ["snapshot", { "turn" => "trn_1", "loop" => "alp_1",
                            "tasks" => [{ "task_key" => "k1", "kind" => "tool_task", "status" => "needs_approval" }],
                            "attention" => { "reason" => "approval_required", "blocked_task_keys" => ["k1"] } }]
    wait_for { @core.called?(:approve) }
    @live << ["turn_status", { "turn_public_id" => "trn_1", "agent_loop_public_id" => "alp_1",
                               "status" => "completed", "loop_status" => "completed" }]
    @live << ["closed", {}]

    assert_equal({ "stopReason" => "end_turn" }, pending.wait(timeout: 5))
    assert_equal [[["alp_1", "k1"], {}]], @core.calls_of(:approve)
    refute_nil seen, "the client was asked from the snapshot's own attention"
    assert_equal "alp_1:k1", seen.dig("toolCall", "toolCallId")
  end
end
