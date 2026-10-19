require "test_helper"
require_relative "../support/contract_fixtures"

# THE DECISIONS A PERSON OWES A RUN, as one list: a model's question and a
# call held for an approver, read from the run's trace and each task's
# detail, each carrying the member verb that ends it. Machines claim and
# commit on the executor plane; people decide here — and an application
# never has to know which door a kind takes.
class ApiRunDecisionsTest < Minitest::Test
  WORKSPACE_ID = "019f0000-0000-7000-8000-000000000101".freeze
  RUN_ID = "019f0000-0000-7000-8000-000000000601".freeze
  RUN_PATH = "/agent_api/v1/workspaces/#{WORKSPACE_ID}/runs/#{RUN_ID}".freeze

  ROW = { "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "visibility" => "visible",
          "created_at" => "2026-09-04T00:00:00Z" }.freeze
  ASK = ROW.merge("key" => "r2t0-ask-1", "kind" => "await_task", "status" => "awaiting_input").freeze
  HELD = ROW.merge("key" => "r3c1", "status" => "needs_approval", "tool_name" => "bash").freeze
  DONE = ROW.merge("key" => "r1t0", "status" => "completed", "tool_name" => "read").freeze
  RUN = { "run" => { "public_id" => RUN_ID, "status" => "running", "tasks" => [DONE, ASK, HELD],
                     "attention" => { "reason" => "awaiting_human", "blocked_task_keys" => ["r2t0-ask-1"] } } }.freeze
  ASK_DETAIL = { "task" => ASK.merge("prompt" => "Migrate now, or in the maintenance window?",
    "options" => ["Now", "In the maintenance window"], "multi" => false) }.freeze
  HELD_DETAIL = { "task" => HELD.merge("tool_input" => { "command" => "git push --force" }) }.freeze

  def context(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member",
      transport: @transport).workspace(WORKSPACE_ID).runs.run(RUN_ID)
  end

  def requests = @transport.requests

  # One run read, then one detail read per pending task — a settled task
  # is nobody's decision and costs no read.
  def test_decisions_are_the_tasks_resting_on_a_person_with_their_questions_and_calls
    decisions = context([[200, {}, RUN], [200, {}, ASK_DETAIL], [200, {}, HELD_DETAIL]]).decisions

    assert_equal [RUN_PATH, "#{RUN_PATH}/tasks/r2t0-ask-1", "#{RUN_PATH}/tasks/r3c1"], requests.map { |r| r.fetch(:path) }
    assert_equal %w[ask approval], decisions.map(&:kind)

    ask, approval = decisions
    assert_predicate ask, :ask?
    assert_equal "r2t0-ask-1", ask.task_key
    assert_equal RUN_ID, ask.run_public_id
    assert_equal "Migrate now, or in the maintenance window?", ask.prompt
    assert_equal ["Now", "In the maintenance window"], ask.options
    assert_equal false, ask.multi

    assert_predicate approval, :approval?
    assert_equal "bash", approval.tool_name
    assert_equal({ "command" => "git push --force" }, approval.tool_input)
    assert_nil approval.prompt
  end

  def test_structured_decisions_keep_fields_and_send_typed_answers
    fields = CybrosAgentTest::ContractFixtures.pack("executor_inbox.json").fetch("structured_ask_fixture").fetch("fields")
    run = { "run" => RUN.fetch("run").merge("tasks" => [ASK]) }
    detail = { "task" => ASK.merge("prompt" => "Settings", "fields" => fields) }
    settled = { "task" => ASK.merge("status" => "completed") }
    decision = context([[200, {}, run], [200, {}, detail], [200, {}, settled]]).decisions.fetch(0)
    assert_equal fields, decision.fields
    answer = { "enabled" => false, "count" => 0 }
    decision.answer(answer: answer)
    assert_equal({ "answer" => answer }, requests.last.fetch(:body))
  end

  def test_mcp_approval_preserves_connection_and_callable_for_the_deciding_client
    detail = CybrosAgentTest::ContractFixtures.pack("mcp_connections.json").fetch("approval_fixture")
    row = detail.fetch("task")
    target = row.fetch("target")
    effect = row.fetch("effect_profile")
    run = { "run" => RUN.fetch("run").merge("tasks" => [row]) }
    decision = context([[200, {}, run], [200, {}, detail]]).decisions.fetch(0)
    assert_equal "work_search", decision.tool_alias
    assert_equal target.fetch("connection_public_id"), decision.target.connection_public_id
    assert_equal "Company account", decision.target.account_label
    assert_nil decision.target.executor_public_id
    assert_equal effect, decision.effect_profile
  end

  def test_a_run_with_nothing_pending_reads_once_and_decides_nothing
    quiet = { "run" => RUN.fetch("run").merge("tasks" => [DONE], "attention" => nil) }

    assert_empty context([[200, {}, quiet]]).decisions
    assert_equal 1, requests.length
  end

  # Each verb is the member door the kind takes: an ask resolves with no
  # token, an approval is approved or denied — every one a POST on the
  # task's own path, never the executor inbox.
  def test_the_verbs_end_each_decision_on_the_member_plane
    settled = { "task" => ASK.merge("status" => "completed") }
    granted = { "task" => HELD.merge("status" => "dispatched") }
    denied = { "task" => HELD.merge("status" => "failed", "error" => { "key" => "approval_denied" }) }
    ask, approval = context([[200, {}, RUN], [200, {}, ASK_DETAIL], [200, {}, HELD_DETAIL],
                         [200, {}, settled], [200, {}, granted], [200, {}, denied]]).decisions

    assert_equal "completed", ask.answer(content: "Now").status
    assert_equal "dispatched", approval.approve.status
    assert_equal "failed", approval.deny(reason: "not on this branch").status

    verbs = requests.drop(3)
    assert_equal [:post, :post, :post], verbs.map { |r| r.fetch(:method) }
    assert_equal ["#{RUN_PATH}/tasks/r2t0-ask-1/resolution", "#{RUN_PATH}/tasks/r3c1/approve", "#{RUN_PATH}/tasks/r3c1/deny"],
      verbs.map { |r| r.fetch(:path) }
    assert_equal({ "content" => "Now" }, verbs[0].fetch(:body), "a model's ask carries no token")
    assert_nil verbs[1].fetch(:body)
    assert_equal({ "reason" => "not on this branch" }, verbs[2].fetch(:body))
  end
end
