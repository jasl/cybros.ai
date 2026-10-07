require "test_helper"
require_relative "../support/contract_fixtures"
require_relative "../support/fake_realtime_client"
require_relative "../support/run_fixtures"

class ApiRunRequestsTest < Minitest::Test
  include CybrosAgentTest::RunFixtures

  # The runner half is reachable FROM the author half, so one object can
  # author a run and then answer the work it parked.
  # THE REQUEST COMPOSITION: one `tool` step under `raw` with
  # the runner named and `bypass` as the inert mode — `approval_rules` the
  # only shell the caller shapes — created, then STARTED; the caller's own
  # idempotency key rides the create. Nothing names a deliverable: the one
  # step is the answer by construction.
  RELAY_TASK = TASK.merge("key" => "call_tool", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "tool_name" => "files_bytes",
    "on_failure" => "propagate").freeze
  RELAY_RUN = RUN.merge("deliverable_task_key" => "call_tool", "tasks" => [RELAY_TASK]).freeze
  RUNNER_ID = "019f0000-0000-7000-8000-000000000301".freeze
  DENY_RULE = { "tool" => "bash", "path" => "command", "match" => "*rm -?? /", "verdict" => "deny",
                "origin" => "author" }.freeze

  def test_request_authors_a_one_task_run_under_raw_and_starts_it
    context = workspace([
      [201, {}, { "run" => RELAY_RUN, "receipt" => { "revision" => 1 } }],
      [200, {}, { "run" => RELAY_RUN.merge("status" => "running") }],
    ]).runs.start_tool_call(
      runner_executor_public_id: RUNNER_ID, tool: "files_bytes", input: { "path" => "note.txt" },
      timeout_ms: 5_000, approval_rules: [DENY_RULE], idempotency_key: "relay-1"
    )

    assert_instance_of CybrosAgent::Api::RunContext, context
    assert_equal RUN_ID, context.run_public_id
    assert_equal :post, request[:method]
    assert_equal RUNS_PATH, request[:path]
    assert_equal "relay-1", request[:headers].fetch("Idempotency-Key")
    assert_equal({
      "steps" => [{ "tool" => { "name" => "files_bytes", "input" => { "path" => "note.txt" }, "key" => "call_tool",
                                "timeout_ms" => 5_000, "route" => { "kind" => "runner", "runner_executor_public_id" => RUNNER_ID } } }],
      "prompt_mechanism" => "raw", "approval_mode" => "bypass", "approval_rules" => [DENY_RULE],
      "default_runner_executor_public_id" => RUNNER_ID,
    }, request[:body].fetch("run"), "one tool step, the shell fixed, the runner named, no deliverable")
    assert_equal :post, request(1)[:method]
    assert_equal "#{RUN_PATH}/start", request(1)[:path], "created AND started: an unstarted request never dispatches"
    assert_equal 2, @transport.requests.length
  end

  def test_request_leaves_the_park_to_the_runner_when_no_timeout_is_given_and_sends_no_rules_unasked
    workspace([
      [201, {}, { "run" => RELAY_RUN, "receipt" => { "revision" => 1 } }],
      [200, {}, { "run" => RELAY_RUN.merge("status" => "running") }],
    ]).runs.start_tool_call(runner_executor_public_id: RUNNER_ID, tool: "process_log",
      input: { "id" => "p-1" }, idempotency_key: "relay-2")

    step = request[:body].dig("run", "steps", 0, "tool")
    refute step.key?("timeout_ms"), "no step clock: the runner's announced park, else the kernel default, stands"
    refute request[:body].fetch("run").key?("approval_rules"), "absent stays absent"
  end

  # A replayed create answers a run already started; its `start` refuses
  # `not_startable`, and that refusal IS "already started". Any other
  # conflict is the caller's to see.
  def test_request_reads_a_replayed_creates_not_startable_as_already_started
    context = workspace([
      [200, {}, { "run" => RELAY_RUN.merge("status" => "running"), "receipt" => { "revision" => 1, "replayed" => true } }],
      [409, {}, { "error" => { "code" => "not_startable", "message" => "already running" } }],
    ]).runs.start_tool_call(runner_executor_public_id: RUNNER_ID, tool: "files_bytes",
      input: { "path" => "note.txt" }, idempotency_key: "relay-1")
    assert_equal RUN_ID, context.run_public_id

    error = assert_raises(CybrosAgent::Api::Conflict) do
      workspace([
        [201, {}, { "run" => RELAY_RUN, "receipt" => { "revision" => 1 } }],
        [409, {}, { "error" => { "code" => "run_busy", "message" => "no" } }],
      ]).runs.start_tool_call(runner_executor_public_id: RUNNER_ID, tool: "files_bytes",
        input: {}, idempotency_key: "relay-3")
    end
    assert_equal "run_busy", error.code
  end

  def test_request_refuses_its_missing_words_before_any_request
    runs = workspace([]).runs
    assert_raises(ArgumentError) { runs.start_tool_call(runner_executor_public_id: "", tool: "read", idempotency_key: "k") }
    assert_raises(ArgumentError) { runs.start_tool_call(runner_executor_public_id: RUNNER_ID, tool: "", idempotency_key: "k") }
    assert_raises(ArgumentError) { runs.start_tool_call(runner_executor_public_id: RUNNER_ID, tool: "read", idempotency_key: "") }
    assert_empty @transport.requests
  end

  # THE POLL: the one task read until terminal. A completed
  # request leaves its run as it is — quiescence completed it; nothing
  # stops a completed run.
  def test_wait_for_tool_result_polls_the_one_task_until_it_is_terminal_and_leaves_a_completed_run_alone
    detail = workspace([
      [200, {}, { "task" => RELAY_TASK.merge("status" => "dispatched") }],
      [200, {}, { "task" => RELAY_TASK.merge("status" => "dispatched") }],
      [200, {}, { "task" => RELAY_TASK.merge("status" => "completed", "output" => "note: hello",
        "content" => [{ "type" => "text", "text" => "note: hello" }], "title" => "read note.txt") }],
    ]).runs.run(RUN_ID).wait_for_tool_result(poll: 0.001)

    assert_equal "completed", detail.task.status
    assert_equal "note: hello", detail.output
    assert_equal "read note.txt", detail.title
    assert_equal ["#{RUN_PATH}/tasks/call_tool"] * 3, @transport.requests.map { |req| req[:path] }
    assert(@transport.requests.all? { |req| req[:method] == :get }, "no stop behind a completed request")
  end

  # A request that did not complete — never claimed and swept
  # `timed_out`, `tool_not_served` at start, denied by a rule — answers its
  # terminal task, `error.key` the word a reader acts on, and STOPS the
  # run it leaves so no attention row of a one-task run lingers.
  def test_wait_for_tool_result_answers_a_failed_request_and_stops_the_run_behind_it
    timed_out = RELAY_TASK.merge("status" => "timed_out", "error" => { "key" => "tool_timeout" },
      "addressed_to" => { "role" => "runner", "executor_public_id" => RUNNER_ID, "presence" => "offline" })
    detail = workspace([
      [200, {}, { "task" => timed_out }],
      [200, {}, { "run" => RELAY_RUN.merge("status" => "canceling") }],
    ]).runs.run(RUN_ID).wait_for_tool_result(poll: 0.001)

    assert_equal "timed_out", detail.task.status
    assert_equal "tool_timeout", detail.task.error.fetch("key")
    assert_nil detail.task.claimed_by, "never claimed"
    assert_equal :post, request(1)[:method]
    assert_equal "#{RUN_PATH}/stop", request(1)[:path]
    assert_equal({ "force" => true }, request(1)[:body], "stop means stop: the settled row keeps its word")
  end

  # The caller's shorter clock: when `patience` runs out the run is
  # stopped the same way and the task read back — a forced stop settles a
  # dispatched row at once, so the answer is still a terminal task.
  def test_wait_for_tool_result_stops_the_run_when_the_callers_patience_runs_out
    detail = workspace([
      [200, {}, { "task" => RELAY_TASK.merge("status" => "dispatched") }],
      [200, {}, { "run" => RELAY_RUN.merge("status" => "canceling") }],
      [200, {}, { "task" => RELAY_TASK.merge("status" => "canceled") }],
    ]).runs.run(RUN_ID).wait_for_tool_result(poll: 0.001, patience: 0)

    assert_equal "canceled", detail.task.status
    assert_equal ["#{RUN_PATH}/tasks/call_tool", "#{RUN_PATH}/stop", "#{RUN_PATH}/tasks/call_tool"],
      @transport.requests.map { |req| req[:path] }
    assert_equal 1, @transport.requests.count { |req| req[:path].end_with?("/stop") }, "stopped once, not again on the terminal read"
  end

  def test_wait_for_tool_result_refuses_a_poll_that_is_not_positive
    assert_raises(ArgumentError) { workspace([]).runs.run(RUN_ID).wait_for_tool_result(poll: 0) }
  end

  def test_the_runner_half_hangs_off_the_same_run
    context = workspace([]).run(RUN_ID).tasks_context("round1")
    assert_equal RUN_ID, context.run_public_id
    assert_equal "round1", context.task_key
  end
end
