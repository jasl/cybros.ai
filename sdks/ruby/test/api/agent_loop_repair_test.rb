require "test_helper"
require_relative "../support/contract_fixtures"

# REPAIRING A HALTED LOOP, and every field this gem used to drop.
#
# A loop resting on an unresolved `halt` failure has no clock: it stands
# there until somebody decides. The kernel routes, implements and
# documents the three verbs that decide — retry, abandon, compact — and
# until this file the only way to reach one was hand-rolled HTTP.
#
# The read half is here for the same reason: `model`, `waiting_on`, the
# trace's `steers` and an await's `prompt` are all served by nexus and
# were all dropped on the way in. That class of defect has bitten once already (a
# task `result` typed String meant every completed loop raised), and it is
# invisible without a fixture written from the WIRE rather than from the
# projection.
class ApiAgentLoopRepairTest < Minitest::Test
  WORKSPACE_ID = "019f0000-0000-7000-8000-000000000101".freeze
  LOOP_ID = "019f0000-0000-7000-8000-000000000601".freeze
  LOOP_PATH = "/agent_api/v1/workspaces/#{WORKSPACE_ID}/agent_loops/#{LOOP_ID}".freeze

  FAILED = {
    "key" => "round1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "failed",
    "on_failure" => "halt", "visibility" => "visible",
    "error" => { "key" => "provider_unavailable", "detail" => "502 from the lane" },
    "model" => { "model" => "dev/acme/text" },
    "created_at" => "2026-09-04T00:00:00Z",
  }.freeze

  def workspace(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member",
      transport: @transport).workspace(WORKSPACE_ID)
  end

  def tasks_context(script)
    workspace(script).agent_loops.agent_loop(LOOP_ID).tasks_context("round1")
  end

  def request(index = 0) = @transport.requests.fetch(index)

  # ---- the three verbs ----

  def test_retry_requeues_the_failed_round_and_answers_the_task
    requeued = FAILED.merge("status" => "waiting", "error" => nil)
    task = tasks_context([[200, {}, { "task" => requeued }]]).retry

    assert_equal :post, request.fetch(:method)
    assert_equal "#{LOOP_PATH}/tasks/round1/retry", request.fetch(:path)
    assert_nil request[:body], "retry without a model keeps the task's selection"
    assert_predicate task, :waiting?
    assert_nil task.error
  end

  def test_retry_can_explicitly_change_only_the_failed_rounds_model
    selected = { "model" => "dev/text", "reasoning_effort" => "low" }
    requeued = FAILED.merge("status" => "waiting", "error" => nil, "model" => selected)
    task = tasks_context([[200, {}, { "task" => requeued }]])
      .retry(model: "dev/text", reasoning_effort: "low")

    assert_equal "#{LOOP_PATH}/tasks/round1/retry", request.fetch(:path)
    assert_equal({ "model" => selected }, request.fetch(:body))
    assert_equal selected, task.model
    assert_predicate task, :waiting?
  end

  def test_abandon_settles_the_failure_so_the_loop_can_move_past_it
    settled = FAILED.merge("failure_resolution" => "abandoned")
    task = tasks_context([[200, {}, { "task" => settled }]]).abandon

    assert_equal "#{LOOP_PATH}/tasks/round1/abandon", request.fetch(:path)
    assert_equal "abandoned", task.failure_resolution
    assert_predicate task, :failed?
  end

  # A person's branch cancel: the call key
  # the model saw, answered as the settled task with its resolution.
  def test_cancel_settles_a_branch_canceled_with_its_resolution
    settled = FAILED.merge("status" => "canceled", "failure_resolution" => "canceled",
      "error" => { "key" => "task_canceled" })
    task = tasks_context([[200, {}, { "task" => settled }]]).cancel

    assert_equal :post, request.fetch(:method)
    assert_equal "#{LOOP_PATH}/tasks/round1/cancel", request.fetch(:path)
    assert_equal "canceled", task.status
    assert_equal "canceled", task.failure_resolution
    assert_equal "task_canceled", task.error.fetch("key")
    assert_nil task.mailed_at

    mailed = tasks_context([[200, {}, { "task" => settled.merge("mailed_at" => "2026-09-06T00:00:09Z") }]]).cancel
    assert_equal "2026-09-06T00:00:09Z", mailed.mailed_at, "a background answer mailed after its turn says when"
  end

  # ---- the approver's verbs ----
  #
  # A tool call resting at `needs_approval` is a person's clock: the
  # loop stays `running` and announces `approval_required` until a
  # principal with write standing decides. The answer is the task as it
  # now stands, carrying the fact — `approval: {origin, decided_by,
  # decided_at}` — so a transcript tells a delegate's grant from the
  # person's.

  HELD = {
    "key" => "r1t0", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "needs_approval",
    "on_failure" => "absorb", "visibility" => "visible", "tool_name" => "bash",
    "created_at" => "2026-09-08T00:00:00Z",
    "addressed_to" => { "role" => "agent_application", "executor_public_id" => "0199-app" },
  }.freeze
  FACT = {
    "origin" => "human", "decided_by" => "019f-owner", "decided_at" => "2026-09-08T00:00:05Z",
  }.freeze

  def test_approve_releases_the_held_call_and_answers_the_task_with_its_fact
    released = HELD.merge("status" => "dispatched", "started_at" => "2026-09-08T00:00:05Z",
      "addressed_to" => { "role" => "runner", "executor_public_id" => "0199-runner" },
      "approval" => FACT)
    task = workspace([[200, {}, { "task" => released }]])
      .agent_loops.agent_loop(LOOP_ID).tasks_context("r1t0").approve

    assert_equal :post, request.fetch(:method)
    assert_equal "#{LOOP_PATH}/tasks/r1t0/approve", request.fetch(:path)
    assert_nil request[:body], "a grant carries no body"
    assert_equal "dispatched", task.status
    assert_predicate task, :started?
    assert_equal FACT, task.approval
    assert_predicate task.approval, :frozen?, "a snapshot, never a live handle"
    assert_equal "runner", task.addressed_to.role, "the release re-ran the addressing site"
  end

  # The fact is absent until a decision — on a held row and on every row
  # this gem's fixtures already carry — and reads nil, never {}.
  def test_a_row_nobody_decided_carries_no_approval_block
    task = workspace([[200, {}, { "task" => HELD }]])
      .agent_loops.agent_loop(LOOP_ID).tasks_context("r1t0").approve

    assert_equal "needs_approval", task.status, "a re-park answers the row still held"
    assert_nil task.approval, "absent reads nil, never {}"
    assert_includes CybrosAgent::Api::TASK_PRE_START_STATUSES, task.status
    refute_predicate task, :started?
  end

  def test_deny_fails_the_held_call_with_the_reason_and_stamps_the_fact
    denied = HELD.merge("status" => "failed",
      "error" => { "key" => "approval_denied", "detail" => "use ls" },
      "approval" => FACT.merge("origin" => "agent", "decided_by" => "019f-agent"))
    task = workspace([[200, {}, { "task" => denied }]])
      .agent_loops.agent_loop(LOOP_ID).tasks_context("r1t0").deny(reason: "use ls")

    assert_equal :post, request.fetch(:method)
    assert_equal "#{LOOP_PATH}/tasks/r1t0/deny", request.fetch(:path)
    assert_equal({ "reason" => "use ls" }, request.fetch(:body))
    assert_predicate task, :failed?
    assert_equal "approval_denied", task.error.fetch("key")
    assert_equal "use ls", task.error.fetch("detail")
    assert_equal "agent", task.approval.fetch("origin"), "a delegate's refusal says so"
  end

  # No reason is an empty body, never `{"reason" => nil}`: the door reads
  # a non-text reason as 400, and nil is not text.
  def test_deny_without_a_reason_sends_no_reason_key
    denied = HELD.merge("status" => "failed", "error" => { "key" => "approval_denied" },
      "approval" => FACT)
    task = workspace([[200, {}, { "task" => denied }]]).agent_loops.agent_loop(LOOP_ID)
      .tasks_context("r1t0").deny

    assert_equal({}, request.fetch(:body))
    assert_equal "approval_denied", task.error.fetch("key")
    assert_nil task.error["detail"]
  end

  # The two refusals the approver's doors add ride the status they carry
  # (409, like every adjudication refusal) with the kernel's code.
  def test_the_approvers_doors_refuse_by_name
    %w[not_awaiting_approval not_adjudicable].each do |code|
      error = assert_raises(CybrosAgent::Api::Conflict) do
        workspace([[409, {}, { "error" => { "code" => code, "message" => "no" } }]])
          .agent_loops.agent_loop(LOOP_ID).tasks_context("r1t0").approve
      end
      assert_equal code, error.code
    end

    error = assert_raises(CybrosAgent::Api::Forbidden) do
      workspace([[403, {}, { "error" => { "code" => "not_authorized", "message" => "no" } }]])
        .agent_loops.agent_loop(LOOP_ID).tasks_context("r1t0").deny(reason: "no")
    end
    assert_equal "not_authorized", error.code, "the approver is any principal with write standing; nobody else"
  end

  # 202, because a summary is work that has been STARTED, not finished —
  # and the answer names the summarizer so a caller can follow the repair
  # without diffing the graph.
  def test_compact_answers_the_round_and_the_summarizer_it_authored
    repaired = FAILED.merge("status" => "waiting", "error" => nil)
    answer = tasks_context([[202, {}, { "task" => repaired, "summary_task_key" => "k1" }]]).compact

    assert_equal "#{LOOP_PATH}/tasks/round1/compact", request.fetch(:path)
    assert_equal "k1", answer.summary_task_key
    assert_equal "round1", answer.task.key
  end

  def test_the_compact_doors_status_is_part_of_its_contract
    assert_raises(CybrosAgent::Api::MalformedResponse) do
      tasks_context([[200, {}, { "task" => FAILED, "summary_task_key" => "k1" }]]).compact
    end
  end

  def test_a_refusal_names_which_precondition_failed
    error = assert_raises(CybrosAgent::Api::Conflict) do
      tasks_context([[409, {}, { "error" => { "code" => "not_retryable",
                                             "message" => "a join settles structurally" } }]]).retry
    end

    assert_equal "not_retryable", error.code
  end

  def test_delete_tombstones_the_record_and_a_live_loop_refuses
    context = workspace([[204, {}, nil]]).agent_loops.agent_loop(LOOP_ID)

    assert_nil context.delete
    assert_equal :delete, request.fetch(:method)
    assert_equal LOOP_PATH, request.fetch(:path)

    busy = workspace([[409, {}, { "error" => { "code" => "agent_loop_busy",
                                              "message" => "stop it first" } }]])
    error = assert_raises(CybrosAgent::Api::Conflict) { busy.agent_loops.agent_loop(LOOP_ID).delete }
    assert_equal "agent_loop_busy", error.code
  end

  # ---- what an adjudicator can act on ----

  # The kernel's own rule: a failure nobody has resolved. Computed from the
  # trace, because `attention.blocked_task_keys` is empty on every REST
  # read today — the ask is narrated on the event stream and the projection
  # has not caught up.
  def test_repairable_tasks_names_the_unresolved_failures_only
    trace = {
      "public_id" => LOOP_ID, "status" => "needs_attention",
      "tasks" => [
        FAILED,
        FAILED.merge("key" => "round2", "status" => "timed_out"),
        FAILED.merge("key" => "round3", "failure_resolution" => "abandoned"),
        FAILED.merge("key" => "round4", "status" => "completed", "error" => nil),
        # An `absorb` failure carries no stamp: the policy settled it in
        # the failing write, and neither verb accepts it.
        FAILED.merge("key" => "round5", "on_failure" => "absorb"),
      ],
      "attention" => { "reason" => "halt_failure" },
      "created_at" => "2026-09-04T00:00:00Z", "updated_at" => "2026-09-04T00:00:00Z",
    }
    agent_loop = workspace([[200, {}, { "agent_loop" => trace }]])
      .agent_loops.agent_loop(LOOP_ID).fetch

    assert_equal %w[round1 round2], agent_loop.repairable_tasks.map(&:key)
    assert_predicate agent_loop, :needs_attention?
    assert_equal "halt_failure", agent_loop.attention.reason
  end

  # THE LOOP HAS NO `failed`: its terminal set is
  # completed|canceled, and the TURN shape is where `failed` lives — a
  # level a retry reopens, which is exactly why the two sets differ.
  def test_the_loops_terminal_set_has_no_failed_and_the_turns_does
    assert_equal %w[completed canceled], CybrosAgent::Api::LOOP_TERMINAL_STATUSES
    assert_equal %w[completed failed canceled], CybrosAgent::Api::TURN_TERMINAL_STATUSES
  end

  def test_a_tool_call_read_carries_what_it_was_asked_to_run
    detail = { "task" => { "key" => "r1t0", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "dispatched",
                           "on_failure" => "halt", "visibility" => "visible",
                           "tool_name" => "read", "tool_input" => { "path" => "/srv/app/x.rb" },
                           "created_at" => "2026-09-04T00:00:00Z" } }
    read = workspace([[200, {}, detail]]).agent_loops.agent_loop(LOOP_ID).task("r1t0")

    assert_equal({ "path" => "/srv/app/x.rb" }, read.tool_input)
    assert_equal "read", read.task.tool_name
  end

  # THE DEBUG DOOR ON A ROUND: the round's sealed
  # request — the entries and the request options, `tools` among them —
  # read off the sealed body; a task with none (a tool row, a round never
  # scheduled) is the kernel's 404 `request_not_sealed`.
  def test_the_rounds_sealed_request_answers_exactly_the_entries_and_the_options
    fixture = CybrosAgentTest::ContractFixtures.pack("agent_loops.json").fetch("valid_task_request_fixture")
    sealed = tasks_context([[200, {}, fixture]]).request

    assert_equal :get, request.fetch(:method)
    assert_equal "#{LOOP_PATH}/tasks/round1/request", request.fetch(:path)
    assert_instance_of CybrosAgent::Api::SealedRequest, sealed
    assert_equal fixture.dig("request", "entries"), sealed.entries
    assert_equal fixture.dig("request", "request_options"), sealed.request_options
    refute_nil sealed.request_options["tools"], "a round's options carry its tool block"
    refute sealed.request_options.key?("instructions"), "the assembled lane's system text rides the list"

    error = assert_raises(CybrosAgent::Api::NotFound) do
      tasks_context([[404, {}, { "error" => { "code" => "request_not_sealed", "message" => "none" } }]]).request
    end
    assert_equal "request_not_sealed", error.code
  end

  # THE EFFECTIVE MECHANISM WORD: the loop's full read names what its rounds were compiled
  # under — `default` on an assembled loop-backed turn, `raw` on a raw one — and a
  # standalone loop, whose word the kernel's assembly compiler settles, reads nil; a listing
  # row, which carries no such key, reads nil too, never a raise.
  def test_the_full_read_carries_the_prompt_mechanism_and_reads_nil_when_absent
    trace = { "public_id" => LOOP_ID, "status" => "completed", "tasks" => [], "prompt_mechanism" => "default" }
    read = workspace([[200, {}, { "agent_loop" => trace }]]).agent_loops.agent_loop(LOOP_ID).fetch
    assert_equal "default", read.prompt_mechanism

    standalone = workspace([[200, {}, { "agent_loop" => trace.merge("prompt_mechanism" => nil) }]])
      .agent_loops.agent_loop(LOOP_ID).fetch
    assert_nil standalone.prompt_mechanism

    absent = workspace([[200, {}, { "agent_loop" => trace.except("prompt_mechanism") }]])
      .agent_loops.agent_loop(LOOP_ID).fetch
    assert_nil absent.prompt_mechanism
  end

  # ---- the list a person reads ----

  def test_the_list_asks_for_what_needs_a_person_most_recent_first
    page = { "agent_loops" => [
      { "public_id" => LOOP_ID, "status" => "running",
        "attention" => { "reason" => "halt_failure" },
        "created_at" => "2026-09-04T00:00:00Z" },
    ], "pagination" => { "next_after" => nil } }
    loops = workspace([[200, {}, page]]).agent_loops
      .list(status: %w[running paused], attention: "any", order: "desc", limit: 10)

    params = request.fetch(:params)
    assert_equal "running,paused", params.fetch("status")
    assert_equal "any", params.fetch("attention")
    assert_equal "desc", params.fetch("order")
    assert_equal 1, loops.items.length
    assert_equal "halt_failure", loops.items.first.attention.reason
  end

  # ---- the fields that were served and dropped ----

  # On the trace a waiting task says which tasks it still waits for; the
  # whole shape is the graph read's, not this one's.
  def test_the_trace_carries_the_lane_a_round_ran_on_and_what_a_waiting_task_waits_for
    trace = {
      "public_id" => LOOP_ID, "status" => "running",
      "tasks" => [
        FAILED.merge("status" => "running", "error" => nil),
        { "key" => "barrier", "kind" => "join_task", "lifetime" => "conversation", "wake" => "auto", "status" => "waiting",
          "waiting_on" => %w[round1], "on_failure" => "halt", "visibility" => "visible",
          "created_at" => "2026-09-04T00:00:00Z" },
      ],
      "created_at" => "2026-09-04T00:00:00Z", "updated_at" => "2026-09-04T00:00:00Z",
    }
    agent_loop = workspace([[200, {}, { "agent_loop" => trace }]])
      .agent_loops.agent_loop(LOOP_ID).fetch

    assert_equal "dev/acme/text",
      agent_loop.task("round1").model.fetch("model")
    assert_equal %w[round1], agent_loop.task("barrier").waiting_on
    assert_empty agent_loop.task("round1").waiting_on, "a started task waits on no task"
  end

  # THE TURN SHAPE beside the loop's row: a standalone loop's
  # `turn` is the frozen algebra over its rows, with its own waiting room;
  # a loop-backed loop's is its TURN row's, naming the turn and its
  # conversation, and hosts no queue of its own.
  def test_the_trace_carries_the_turn_shape_and_the_loop_hosted_queue
    trace = {
      "public_id" => LOOP_ID, "status" => "needs_attention",
      "tasks" => [FAILED],
      "turn" => { "status" => "failed", "failure_reason_key" => "halt_failure" },
      "input_queue" => { "limit" => 16, "held" => 2 },
      "created_at" => "2026-09-04T00:00:00Z", "updated_at" => "2026-09-04T00:00:00Z",
    }
    agent_loop = workspace([[200, {}, { "agent_loop" => trace }]])
      .agent_loops.agent_loop(LOOP_ID).fetch

    assert_predicate agent_loop.turn, :failed?
    assert_equal "halt_failure", agent_loop.turn.failure_reason_key
    refute_predicate agent_loop.turn, :loop_backed?
    assert_nil agent_loop.turn.model, "a standalone loop's turn names no model: each task carries its own"
    assert_nil agent_loop.turn.answering_user_public_id
    assert_equal 2, agent_loop.input_queue.held
    refute_predicate agent_loop.input_queue, :full?

    # THE STATED PLACE: a loop-backed turn carries the model it runs
    # on, in the loop's `{model, reasoning_effort}` shape.
    hosted = trace.merge(
      "turn" => { "status" => "running", "public_id" => "019f0000-0000-7000-8000-0000000007a1",
                  "conversation_public_id" => "019f0000-0000-7000-8000-0000000005a1",
                  "answering_user_public_id" => "019f0000-0000-7000-8000-000000000002",
                  "model" => { "model" => "openrouter/fixture/priced", "reasoning_effort" => "low" } }
    ).except("input_queue")
    agent_loop = workspace([[200, {}, { "agent_loop" => hosted }]])
      .agent_loops.agent_loop(LOOP_ID).fetch
    assert_predicate agent_loop.turn, :loop_backed?
    assert_equal "019f0000-0000-7000-8000-0000000005a1", agent_loop.turn.conversation_public_id
    assert_equal "019f0000-0000-7000-8000-000000000002", agent_loop.turn.answering_user_public_id
    assert_nil agent_loop.turn.failure_reason_key
    assert_equal({ "model" => "openrouter/fixture/priced", "reasoning_effort" => "low" }, agent_loop.turn.model)
    assert_equal "openrouter/fixture/priced", agent_loop.turn.model_ref
    assert_nil agent_loop.input_queue, "a loop-backed loop's queue is its conversation's"
  end

  # A listing row carries the turn shape but never the queue; an older
  # fixture with neither still parses.
  def test_a_trace_without_the_turn_shape_reads_as_none
    trace = { "public_id" => LOOP_ID, "status" => "running",
              "tasks" => [], "created_at" => "2026-09-04T00:00:00Z",
              "updated_at" => "2026-09-04T00:00:00Z" }

    agent_loop = workspace([[200, {}, { "agent_loop" => trace }]])
      .agent_loops.agent_loop(LOOP_ID).fetch
    assert_nil agent_loop.turn
    assert_nil agent_loop.input_queue
  end

  # THE BYTES A ROUND WAS SEALED WITH: the kernel
  # stores the request body's size and serves it on the round's read; a
  # fixed-field projection that lacked the key would drop it silently.
  def test_a_round_read_carries_the_bytes_its_request_was_sealed_with
    detail = { "task" => { "key" => "r2", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed",
                           "on_failure" => "halt", "visibility" => "visible",
                           "model" => { "model" => "dev/acme/text" },
                           "output" => "done", "request_bytes" => 971_311,
                           "created_at" => "2026-09-12T00:00:00Z" } }
    read = workspace([[200, {}, detail]]).agent_loops.agent_loop(LOOP_ID).task("r2")

    assert_equal 971_311, read.request_bytes
    assert_equal "done", read.output
  end

  def test_round_declarations_preserve_alias_facts_and_distinguish_no_tools_from_no_evidence
    pack = CybrosAgentTest::ContractFixtures.pack("agent_loops.json")
    fixture = pack.fetch("valid_task_detail_fixture")
    read = workspace([[200, {}, fixture]]).agent_loops.agent_loop(LOOP_ID).task("r1")

    assert_equal fixture.dig("task", "tool_definitions"), read.tool_definitions
    clarification = read.tool_definitions.find { |entry| entry.dig("function", "name") == "Clarify" }
    assert_equal "nexus.human.ask", clarification.fetch("canonical")
    assert_equal({ "question" => { "maps_to" => "prompt" } }, clarification.fetch("params"))
    assert_equal ["multi"], clarification.fetch("omit")

    empty = workspace([[200, {}, pack.fetch("valid_toolless_task_detail_fixture")]])
      .agent_loops.agent_loop(LOOP_ID).task("r2")
    assert_equal [], empty.tool_definitions

    missing = { "task" => fixture.fetch("task").except("tool_definitions") }
    unknown = workspace([[200, {}, missing]]).agent_loops.agent_loop(LOOP_ID).task("r1")
    assert_nil unknown.tool_definitions
    asked = workspace([[200, {}, pack.fetch("valid_ask_task_detail_fixture")]])
      .agent_loops.agent_loop(LOOP_ID).task("r1t0-ask-1")
    assert_nil asked.tool_definitions
  end

  # THE QUESTION AN AWAIT IS ASKING. A model composes it with `g.ask`, the
  # kernel seals it, and a person answering it could not read it.
  def test_a_task_read_carries_the_question_an_await_is_asking
    detail = { "task" => { "key" => "ask-1", "kind" => "await_task", "lifetime" => "conversation", "wake" => "auto", "status" => "awaiting_input",
                           "on_failure" => "halt", "visibility" => "visible",
                           "prompt" => "Which database should I migrate first?",
                           "created_at" => "2026-09-04T00:00:00Z" } }
    read = workspace([[200, {}, detail]]).agent_loops.agent_loop(LOOP_ID).task("ask-1")

    assert_equal "Which database should I migrate first?", read.prompt
    assert_nil read.options, "an ask that gave no choices carries none"
    assert_nil read.multi
    assert_nil read.tool_input, "an await has nothing to run"
    assert_predicate read.task, :started?
    assert_equal "await_task", read.task.kind

    # THE CHOICES AS DATA: the pack's ask detail
    # carries `options` and `multi` beside the question.
    fixture = CybrosAgentTest::ContractFixtures.pack("agent_loops.json").fetch("valid_ask_task_detail_fixture")
    asked = workspace([[200, {}, fixture]]).agent_loops.agent_loop(LOOP_ID).task("r1t0-ask-1")
    assert_equal fixture.dig("task", "prompt"), asked.prompt
    assert_equal fixture.dig("task", "options"), asked.options
    assert_equal false, asked.multi
  end
end
