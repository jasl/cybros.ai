require "test_helper"

# THE PARK, THE ASK, CANCEL through the surface
# against the core double: the three options → the Core verbs, the
# reject naming the client, the cancel cascade with `$/cancel_request`,
# the ask with and without the form.
class AcpPermissionsTest < Minitest::Test
  Methods = Rho::Acp::Methods
  PARK = ["attention_required", { "reason" => "approval_required", "blocked_task_keys" => ["k1"] }].freeze
  ASK = ["attention_required", { "reason" => "awaiting_human", "blocked_task_keys" => ["a1"] }].freeze
  SNAPSHOT = ["snapshot", { "turn" => "trn_1", "run_public_id" => "alp_1" }].freeze
  COMPLETED = ["turn_status", { "turn_public_id" => "trn_1", "run_public_id" => "alp_1", "status" => "completed", "run_status" => "completed" }].freeze
  CANCELED = ["turn_status", { "turn_public_id" => "trn_1", "run_public_id" => "alp_1", "status" => "canceled", "run_status" => "canceled" }].freeze
  CLOSED = ["closed", {}].freeze

  def setup
    @core = RhoAcpTest::CoreDouble.new
    @core.tasks[["alp_1", "k1"]] = { "tool_name" => "bash", "tool_input" => { "command" => "rm -rf build" } }
    @core.tasks[["alp_1", "a1"]] = { "kind" => "ask", "prompt" => "Which branch?" }
    @live = Queue.new
    @core.events["cnv_1"] = @live
  end

  def teardown
    @harness&.close
  end

  def open(policy: RhoAcpTest.permission_policy("allow"), capabilities: RhoAcpTest::AgentHarness.capabilities, mode: "ask")
    @harness = RhoAcpTest::AgentHarness.new(core: @core, mode: mode)
    @harness.policy = policy
    @harness.initialize_agent(capabilities: capabilities)
    @harness.new_session(cwd: "/tmp")
    @harness
  end

  def park_then_complete(policy:)
    harness = open(policy: policy)
    pending = harness.start_prompt("cnv_1", "clean up")
    @live << SNAPSHOT
    @live << ["task_status", { "task_key" => "k1", "kind" => "tool_task", "status" => "needs_approval" }]
    @live << PARK
    wait_for { @core.called?(:approve) || @core.called?(:deny) }
    @live << COMPLETED
    @live << CLOSED
    [harness, pending.wait(timeout: 5)]
  end

  def wait_for(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  def test_allow_approves_the_key_and_the_request_carries_the_call_and_the_three_options
    seen = nil
    policy = lambda do |inbound|
      seen = inbound.params
      inbound.respond("outcome" => { "outcome" => "selected", "optionId" => "allow" })
    end
    harness, answer = park_then_complete(policy: policy)

    assert_equal({ "stopReason" => "end_turn" }, answer)
    assert_equal [[["alp_1", "k1"], {}]], @core.calls_of(:approve)
    refute @core.called?(:deny)
    assert_equal "cnv_1", seen["sessionId"]
    assert_equal({ "toolCallId" => "alp_1:k1", "title" => "bash rm -rf build", "kind" => "execute",
                   "rawInput" => { "command" => "rm -rf build" } }, seen["toolCall"])
    assert_equal [
      { "optionId" => "allow", "name" => "Allow", "kind" => "allow_once" },
      { "optionId" => "always", "name" => "Always allow — rho remembers this call's shape until its daemon restarts", "kind" => "allow_always" },
      { "optionId" => "reject", "name" => "Reject", "kind" => "reject_once" },
    ], seen["options"]
    # The tool_call was out before the request, pending.
    call = harness.updates_of("tool_call").first
    assert_equal "pending", call.dig("update", "status")
    assert_equal 1, @core.calls_of(:task).length
  end

  def test_always_approves_with_the_grant
    _harness, answer = park_then_complete(policy: RhoAcpTest.permission_policy("always"))

    assert_equal "end_turn", answer["stopReason"]
    assert_equal [[["alp_1", "k1"], { always: true }]], @core.calls_of(:approve)
  end

  def test_web_fetch_always_names_the_site_scope_and_uses_the_core_grant
    url = "https://docs.example:8443/guide?version=2"
    @core.tasks[["alp_1", "k1"]] = { "tool_name" => "web_fetch", "tool_input" => { "url" => url } }
    seen = nil
    policy = lambda do |inbound|
      seen = inbound.params
      inbound.respond("outcome" => { "outcome" => "selected", "optionId" => "always" })
    end
    _harness, answer = park_then_complete(policy: policy)

    assert_equal "end_turn", answer["stopReason"]
    assert_equal({ "url" => url }, seen.dig("toolCall", "rawInput"))
    assert_equal({ "optionId" => "always", "name" => "Allow this site until rho restarts", "kind" => "allow_always" },
      seen.fetch("options").find { |option| option["optionId"] == "always" })
    assert_equal [[["alp_1", "k1"], { always: true }]], @core.calls_of(:approve)
    assert_equal 1, @core.calls_of(:task).length
  end

  def test_reject_denies_naming_the_client
    _harness, answer = park_then_complete(policy: RhoAcpTest.permission_policy("reject"))

    assert_equal "end_turn", answer["stopReason"]
    assert_equal [[["alp_1", "k1"], { reason: "rejected in test-editor" }]], @core.calls_of(:deny)
    refute @core.called?(:approve)
  end

  def test_a_cancelled_outcome_decides_nothing
    asked = false
    policy = lambda do |inbound|
      inbound.respond("outcome" => { "outcome" => "cancelled" })
      asked = true
    end
    harness = open(policy: policy)
    pending = harness.start_prompt("cnv_1", "clean up")
    @live << SNAPSHOT << PARK
    wait_for { asked }
    sleep 0.2
    @live << COMPLETED << CLOSED

    assert_equal "end_turn", pending.wait(timeout: 5)["stopReason"]
    refute @core.called?(:approve)
    refute @core.called?(:deny)
  end

  def test_a_request_the_client_cancels_on_its_own_is_denied_as_gone_away
    policy = ->(inbound) { inbound.fail_cancelled }
    _harness, answer = park_then_complete(policy: policy)

    assert_equal "end_turn", answer["stopReason"]
    assert_equal [[["alp_1", "k1"], { reason: "the client went away" }]], @core.calls_of(:deny)
  end

  def test_a_key_the_daemon_refuses_is_dropped_silently
    @core.refuse(:approve, "k1 is not held for approval (completed)", code: "malformed_body", status: 400)
    harness, answer = park_then_complete(policy: RhoAcpTest.permission_policy("allow"))

    assert_equal "end_turn", answer["stopReason"]
    assert_includes harness.stderr, "k1 is not held for approval"
  end

  def test_session_cancel_cascades_cancel_request_to_the_held_permission_and_answers_cancelled
    harness = open(policy: :hold)
    pending = harness.start_prompt("cnv_1", "clean up")
    @live << SNAPSHOT << PARK
    held = harness.await_held
    assert_equal Methods::SESSION_REQUEST_PERMISSION, held.method

    harness.notify(Methods::SESSION_CANCEL, { "sessionId" => "cnv_1" })
    wait_for { held.cancelled? }
    held.fail_cancelled
    wait_for { @core.called?(:stop) }
    @live << CANCELED << CLOSED

    assert_equal({ "stopReason" => "cancelled" }, pending.wait(timeout: 5))
    assert_equal [[["cnv_1"], { force: true }]], @core.calls_of(:stop)
    refute @core.called?(:deny), "a deny racing a cancel is a refusal to log"
    refute @core.called?(:approve)
  end

  def test_a_stop_the_daemon_refuses_never_makes_the_cancel_an_error
    @core.refuse(:stop, "not_running: nothing is in flight", code: "malformed_body", status: 400)
    harness = open(policy: :hold)
    pending = harness.start_prompt("cnv_1", "clean up")
    @live << SNAPSHOT << PARK
    held = harness.await_held
    harness.notify(Methods::SESSION_CANCEL, { "sessionId" => "cnv_1" })
    wait_for { held.cancelled? }
    held.fail_cancelled
    wait_for { @core.called?(:stop) }
    @live << CANCELED << CLOSED

    assert_equal "cancelled", pending.wait(timeout: 5)["stopReason"]
    assert_includes harness.stderr, "not_running"
  end

  def test_cancel_request_on_the_prompt_is_the_cancel_path
    harness = open(policy: :hold)
    pending = harness.start_prompt("cnv_1", "clean up")
    @live << SNAPSHOT << PARK
    held = harness.await_held
    pending.cancel
    wait_for { held.cancelled? }
    held.fail_cancelled
    wait_for { @core.called?(:stop) }
    @live << CANCELED << CLOSED

    assert_equal "cancelled", pending.wait(timeout: 5)["stopReason"]
  end

  def test_the_ask_with_the_form_is_an_elicitation_answered_and_the_turn_rejoined
    seen = nil
    policy = lambda do |inbound|
      seen = inbound.params
      inbound.respond("action" => "accept", "content" => { "answer" => "main" })
    end
    @core.events["cnv_1"] = [[SNAPSHOT, ASK], [SNAPSHOT, ["text_delta", { "text" => "done" }], COMPLETED, CLOSED]]
    harness = open(policy: policy, capabilities: RhoAcpTest::AgentHarness.capabilities(form: true))

    answer = harness.prompt("cnv_1", "merge it")

    assert_equal "end_turn", answer["stopReason"]
    refute_nil seen, "no elicitation/create reached the client"
    assert_equal "cnv_1", seen["sessionId"]
    assert_equal "form", seen["mode"]
    assert_equal "Which branch?", seen["message"]
    assert_equal({ "type" => "object", "properties" => { "answer" => { "type" => "string" } }, "required" => ["answer"] }, seen["requestedSchema"])
    assert_equal [[["alp_1", "a1", "main"], {}]], @core.calls_of(:answer)
    assert_equal 2, @core.calls_of(:follower_events).length
    assert_equal ["done"], harness.updates_of("agent_message_chunk").map { |u| u.dig("update", "content", "text") }
    assert_nil harness.agent.sessions["cnv_1"].held
  end

  # THE RE-JOIN WAITS FOR THE FOLLOWER (`Turn.catch_up`): the row still
  # parks the ask for two reads after the answer — the kernel's clearing
  # note has not landed — and the re-join opens only once it moved, so
  # the editor sees ONE form for one ask and the daemon ONE answer.
  def test_the_answered_form_rejoins_only_after_the_follower_saw_the_ask_resolve
    @core = RhoAcpTest::SettlingCore.new
    @core.tasks[["alp_1", "a1"]] = { "kind" => "ask", "prompt" => "Which branch?" }
    @core.events["cnv_1"] = [[SNAPSHOT, ASK], [SNAPSHOT, COMPLETED, CLOSED]]
    @core.settle("cnv_1", reads: 2,
      stale: { "public_id" => "cnv_1", "turn" => "trn_1", "run_public_id" => "alp_1",
               "attention" => { "reason" => "awaiting_human", "blocked_task_keys" => ["a1"] } },
      settled: { "public_id" => "cnv_1", "turn" => "trn_1", "run_public_id" => "alp_1", "status" => "running" })
    forms = 0
    policy = lambda do |inbound|
      forms += 1
      inbound.respond("action" => "accept", "content" => { "answer" => "main" })
    end
    harness = open(policy: policy, capabilities: RhoAcpTest::AgentHarness.capabilities(form: true))

    assert_equal "end_turn", harness.prompt("cnv_1", "merge it")["stopReason"]
    assert_equal 1, forms, "one form for one ask"
    assert_equal 1, @core.calls_of(:answer).length
    assert_equal 2, @core.calls_of(:follower_events).length
    assert_operator @core.calls_of(:run_row).length, :>=, 3, "the row was polled until it moved"
  end

  # The question streamed without a form is never counted against the
  # daemon's accumulator: the re-join after the answer emits every byte
  # the reply grew by, the question's length subtracted from nothing.
  def test_the_held_ask_rejoins_after_the_row_moved_and_the_question_is_not_counted
    @core = RhoAcpTest::SettlingCore.new
    @core.tasks[["alp_1", "a1"]] = { "kind" => "ask", "prompt" => "Which branch?" }
    @core.events["cnv_1"] = [
      [["snapshot", { "turn" => "trn_1", "run_public_id" => "alp_1", "text" => "hi ", "text_length" => 3 }], ASK],
      [["snapshot", { "turn" => "trn_1", "run_public_id" => "alp_1", "text" => "hi done", "text_length" => 7 }], COMPLETED, CLOSED],
    ]
    @core.settle("cnv_1", reads: 2,
      stale: { "public_id" => "cnv_1", "turn" => "trn_1", "run_public_id" => "alp_1",
               "attention" => { "reason" => "awaiting_human", "blocked_task_keys" => ["a1"] } },
      settled: { "public_id" => "cnv_1", "turn" => "trn_1", "run_public_id" => "alp_1", "status" => "running" })
    harness = open

    assert_equal "end_turn", harness.prompt("cnv_1", "merge it")["stopReason"]
    assert_equal "end_turn", harness.prompt("cnv_1", "main")["stopReason"]
    assert_equal ["hi ", "Which branch?", "done"],
      harness.updates_of("agent_message_chunk").map { |u| u.dig("update", "content", "text") }
    assert_equal [[["alp_1", "a1", "main"], {}]], @core.calls_of(:answer)
    assert_operator @core.calls_of(:run_row).length, :>=, 3
  end

  def test_catch_up_ends_at_its_bound_and_on_the_cancel_flag
    session = Rho::Acp::Agent::Session.new(id: "cnv_1", mode: "ask", model: nil, root: "/tmp")
    @core.rows["cnv_1"] = { "public_id" => "cnv_1", "status" => "failed" }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_nil Rho::Acp::Agent::Turn.catch_up(@core, session, bound: 0.3) { |row| row["status"] != "failed" }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.3
    assert_operator @core.calls_of(:run_row).length, :>=, 2

    session.request_cancel!
    assert_raises(Rho::Acp::Agent::Turn::Cancelled) { Rho::Acp::Agent::Turn.catch_up(@core, session) { true } }

    @core.rows.delete("cnv_1")
    assert_nil Rho::Acp::Agent::Turn.catch_up(@core, Rho::Acp::Agent::Session.new(id: "cnv_1", mode: "ask", model: nil, root: "/tmp")) { false },
      "a row the daemon does not answer ends the wait: the follow says so"
  end

  def test_a_declined_form_answers_the_ask_failed
    policy = ->(inbound) { inbound.respond("action" => "decline") }
    @core.events["cnv_1"] = [[SNAPSHOT, ASK], [SNAPSHOT, COMPLETED, CLOSED]]
    harness = open(policy: policy, capabilities: RhoAcpTest::AgentHarness.capabilities(form: true))

    assert_equal "end_turn", harness.prompt("cnv_1", "merge it")["stopReason"]
    assert_equal [[["alp_1", "a1", ""], { outcome: "failed" }]], @core.calls_of(:answer)
  end

  def test_a_cancelled_form_holds_the_ask
    policy = ->(inbound) { inbound.respond("action" => "cancel") }
    @core.events["cnv_1"] = [[SNAPSHOT, ASK]]
    harness = open(policy: policy, capabilities: RhoAcpTest::AgentHarness.capabilities(form: true))

    assert_equal "end_turn", harness.prompt("cnv_1", "merge it")["stopReason"]
    refute @core.called?(:answer)
    assert_equal Rho::Acp::Agent::Hold.new(run_public_id: "alp_1", key: "a1", turn: "trn_1"), harness.agent.sessions["cnv_1"].held
  end

  def test_the_ask_without_the_form_streams_the_question_ends_the_turn_and_the_next_prompt_answers_it
    @core.events["cnv_1"] = [[SNAPSHOT, ASK], [SNAPSHOT, COMPLETED, CLOSED]]
    harness = open

    first = harness.prompt("cnv_1", "merge it")
    assert_equal "end_turn", first["stopReason"]
    question = harness.updates_of("agent_message_chunk").last
    assert_equal "Which branch?", question.dig("update", "content", "text")
    assert_equal "trn_1:0", question.dig("update", "messageId")
    assert_equal Rho::Acp::Agent::Hold.new(run_public_id: "alp_1", key: "a1", turn: "trn_1"), harness.agent.sessions["cnv_1"].held

    second = harness.prompt("cnv_1", "main")
    assert_equal "end_turn", second["stopReason"]
    assert_equal [[["alp_1", "a1", "main"], {}]], @core.calls_of(:answer)
    assert_equal 1, @core.calls_of(:say).length, "the answer is never a new say"
    assert_nil harness.agent.sessions["cnv_1"].held
  end

  def test_session_cancel_while_holding_drops_the_hold
    @core.events["cnv_1"] = [[SNAPSHOT, ASK], [SNAPSHOT, COMPLETED, CLOSED]]
    harness = open
    harness.prompt("cnv_1", "merge it")
    harness.notify(Methods::SESSION_CANCEL, { "sessionId" => "cnv_1" })
    wait_for { @core.called?(:stop) }

    assert_nil harness.agent.sessions["cnv_1"].held
    harness.prompt("cnv_1", "start over")
    assert_equal 2, @core.calls_of(:say).length
    refute @core.called?(:answer)
  end

  def test_a_keyless_park_ends_the_turn
    @core.events["cnv_1"] = [[SNAPSHOT, ["attention_required", { "reason" => "approval_required", "blocked_task_keys" => [] }]]]
    harness = open

    assert_equal "end_turn", harness.prompt("cnv_1", "go")["stopReason"]
    assert_nil harness.agent.sessions["cnv_1"].held
  end

  def test_under_bypass_the_say_carries_no_approval_mode_and_under_ask_the_word
    @core.events["cnv_1"] = [[SNAPSHOT, COMPLETED, CLOSED], [SNAPSHOT, COMPLETED, CLOSED]]
    harness = open(mode: "bypass")
    harness.prompt("cnv_1", "one")
    harness.request(Methods::SESSION_SET_MODE, { "sessionId" => "cnv_1", "modeId" => "rules" })
    harness.prompt("cnv_1", "two")

    assert_equal [nil, "rules"], @core.calls_of(:say).map { |_args, kwargs| kwargs[:approval_mode] }
  end
end
