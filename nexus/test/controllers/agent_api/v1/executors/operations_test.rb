require "test_helper"

class AgentAPI::V1::Executors::TaskOperationsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!
    @runner = suite_runner
    @runner.announce(tools: RunAuthoringTestHelper::TEST_SERVED_TOOLS + [{
      "name" => "program", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
    }])
    @loop = seed(declared_tool("program", "program", "route" => { "kind" => "runner" }, "model_defaults" => {
      "tools" => fixture_runner_declarations([RunLaneTestHelper::READ_TOOL]),
      "model" => { "model" => "dev/mock-text" },
    }))
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: @loop, acting_user: @human))
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    @parent = @loop.agent_run_tasks.sole
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: @loop, task_key: @parent.node_key, executor: @runner
    ))
    assert_predicate claimed, :accepted?
    @parent = claimed.value
    @token = @parent.claim_token
  end

  test "an accepted operation survives response loss and its observation replays false" do
    request = { kind: "tool", name: "read_file", input: { path: "one" } }
    submit("op_0", request)
    assert_response :created
    operation = response.parsed_body.fetch("operation")
    child_key = operation.dig("receipt", "task_keys").sole
    assert_equal 1, operation.fetch("position")
    assert_equal @parent.id, @loop.reload.deliverable_node_id

    submit("op_0", request)
    assert_response :ok
    assert_equal operation, response.parsed_body.fetch("operation")
    assert_equal 2, @loop.agent_run_tasks.count

    submit("op_0", request.merge(input: { path: "two" }))
    assert_response :conflict
    assert_equal "operation_mismatch", response.parsed_body.dig("error", "code")

    observe(1)
    assert_response :ok
    assert_nil response.parsed_body.fetch("observation")
    assert_equal "dispatched", @parent.reload.status

    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    child = @loop.agent_run_tasks.find_by!(node_key: child_key)
    claim = Executors::Claim.call(Executors::Claim::Command.new(agent_run: @loop, task_key: child_key, executor: @runner))
    assert_predicate claim, :accepted?
    settled = AgentRuns::Parks::Settle.call(node: claim.value, claim_token: claim.value.claim_token,
      content: "read", structured_content: false)
    assert_predicate settled, :applied?
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    assert_equal "dispatched", @parent.reload.status
    assert_equal @token, @parent.claim_token
    assert_equal 0, @parent.execution_generation

    observe(1)
    assert_response :ok
    observation = response.parsed_body.fetch("observation")
    assert_equal false, observation.dig("outcome", "structured_content")
    assert_equal 2, observation.fetch("position")
    observe(1)
    assert_equal observation, response.parsed_body.fetch("observation")

    get route("operations"), headers: bearer.merge("Claim-Token" => @token)
    assert_response :ok
    assert_equal %w[operation observation], response.parsed_body.dig("operations", "trace").pluck("type")
    assert_equal 1, @parent.task_operations.count
    assert_equal child_key, observation.dig("outcome", "task_key")
  end

  test "a refused undeclared call is a durable outcome and cannot accept work on replay" do
    request = { kind: "tool", name: "write_file", input: {} }
    submit("op_0", request)
    assert_response :created
    event = response.parsed_body.fetch("operation")
    assert_equal "unknown_tool_name", event.dig("refusal", "code")
    assert_equal 1, @loop.agent_run_tasks.count
    observe(1)
    assert_response :ok
    assert_equal event["refusal"], response.parsed_body.dig("observation", "refusal")
    submit("op_0", request)
    assert_response :ok
    assert_equal event, response.parsed_body.fetch("operation")
  end

  test "standalone work without model context gains no model or tool authority" do
    AgentRunTask.where(id: @parent.id).update_all(operation_context: nil)
    submit("model", { kind: "model", input: { prompt: "Review", model: "dev/mock-text" } })
    assert_response :created
    assert_equal "context_not_authorable", response.parsed_body.dig("operation", "refusal", "code")
    submit("tool", { kind: "tool", name: "read_file", input: {} })
    assert_response :created
    assert_equal "unknown_tool_name", response.parsed_body.dig("operation", "refusal", "code")
    assert_equal 1, @loop.agent_run_tasks.count
  end

  test "operation reads and mutations require the original claim token" do
    get route("operations"), headers: bearer.merge("Claim-Token" => "another-claim")
    assert_response :conflict
    assert_equal "not_claimant", response.parsed_body.dig("error", "code")
    @token = "another-claim"
    submit("tool", { kind: "tool", name: "read_file", input: {} })
    assert_response :conflict
    assert_equal "not_claimant", response.parsed_body.dig("error", "code")
    assert_empty @parent.task_operations
  end

  test "trace limits reject invalid and out of range values without changing operations" do
    [-1, 0, "abc", 201].each do |limit|
      get route("operations"), headers: bearer.merge("Claim-Token" => @token), params: { limit: limit }
      assert_response :bad_request
      assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    end
    get route("operations"), headers: bearer.merge("Claim-Token" => @token), params: { limit: 200 }
    assert_response :ok
    assert_empty response.parsed_body.dig("operations", "trace")
    assert_empty @parent.task_operations
  end

  test "a stale observation position refuses without skipping accepted events" do
    submit("tool", { kind: "tool", name: "read_file", input: {} })
    observe(0)
    assert_response :conflict
    assert_equal "operation_position_changed", response.parsed_body.dig("error", "code")
    observe(1)
    assert_response :ok
    assert_nil response.parsed_body.fetch("observation")
    assert_equal 1, response.parsed_body.fetch("position")
  end

  test "replaying observations advances only through the returned event" do
    submit("a", { kind: "tool", name: "write_file", input: {} })
    submit("b", { kind: "tool", name: "write_file", input: {} })
    observe(2)
    first = response.parsed_body.fetch("observation")
    observe(3)
    second = response.parsed_body.fetch("observation")

    observe(2)
    assert_equal first, response.parsed_body.fetch("observation")
    assert_equal 3, response.parsed_body.fetch("position")
    observe(response.parsed_body.fetch("position"))
    assert_equal second, response.parsed_body.fetch("observation")
    assert_equal 4, response.parsed_body.fetch("position")
  end

  test "unknown operation fields are recorded refusals without accepting child work" do
    request = { kind: "tool", name: "read_file", input: { path: "one" }, after: ["previous"] }
    submit("bad_fields", request)
    assert_response :created
    event = response.parsed_body.fetch("operation")
    assert_equal "unknown_fields", event.dig("refusal", "code")
    assert_equal 1, @loop.agent_run_tasks.count

    submit("bad_fields", request)
    assert_response :ok
    assert_equal event, response.parsed_body.fetch("operation")
    observe(1)
    assert_equal event.fetch("refusal"), response.parsed_body.dig("observation", "refusal")
  end

  test "observation replay follows recorded completion order instead of acceptance order" do
    children = %w[a b c].to_h do |key|
      submit(key, { kind: "tool", name: "read_file", input: { path: key } })
      assert_response :created
      [key, response.parsed_body.dig("operation", "receipt", "task_keys").sole]
    end
    observations = %w[c b a].each_with_index.map do |key, index|
      finish(children.fetch(key), structured_content: { "key" => key })
      observe(3 + index)
      assert_response :ok
      response.parsed_body.fetch("observation")
    end

    observations.each_with_index do |event, index|
      observe(3 + index)
      assert_response :ok
      assert_equal event, response.parsed_body.fetch("observation")
      assert_equal 4 + index, response.parsed_body.fetch("position")
    end
  end

  test "a partially finished batch remains unobserved until its final result settles" do
    submit("batch", { kind: "steps", input: [parallel(declared_tool("a", "read_file"), declared_tool("b", "read_file"))] })
    assert_response :created
    receipt = response.parsed_body.dig("operation", "receipt")
    finish(receipt.fetch("keys").fetch("a"), structured_content: { "a" => 1 })
    observe(1)
    assert_response :ok
    assert_nil response.parsed_body.fetch("observation")
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    assert_equal "dispatched", @parent.reload.status
    finish(receipt.fetch("keys").fetch("b"), structured_content: { "b" => 2 })
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    assert_equal "dispatched", @parent.reload.status
    observe(1)
    assert_equal 2, response.parsed_body.dig("observation", "outcome", "results").length
    assert_equal @token, @parent.claim_token
  end

  test "batch validation is atomic and malformed shapes are durable refusals" do
    submit("bad", { kind: "steps", input: [declared_tool("a", "read_file"), declared_tool("b", "write_file")] })
    assert_response :created
    assert_equal "unknown_tool_name", response.parsed_body.dig("operation", "refusal", "code")
    assert_equal 1, @loop.agent_run_tasks.count
    submit("shape", { kind: "steps", input: [42] })
    assert_response :created
    assert_equal "invalid_steps", response.parsed_body.dig("operation", "refusal", "code")
    assert_equal 1, @loop.agent_run_tasks.count
    submit("parallel_shape", { kind: "steps", input: [{ parallel: { tool: "read_file" } }] })
    assert_response :created
    assert_equal "invalid_steps", response.parsed_body.dig("operation", "refusal", "code")
    assert_equal 1, @loop.agent_run_tasks.count
  end

  test "models and kernel aliases use the frozen declaration and preserve model origin" do
    definitions = Nexus::ToolDeclarations::Render.render([
      RunLaneTestHelper::READ_TOOL, RunLaneTestHelper::AGENT_ALIAS,
    ])
    AgentRunTask.where(id: @parent.id).update_all(authored_by: "model", operation_context: {
      "tools" => definitions, "model" => { "model" => "dev/mock-text" },
    })

    submit("model", { kind: "model", input: { prompt: "Review the facts", tools: ["Agent"] } })
    assert_response :created
    receipt = response.parsed_body.dig("operation", "receipt")
    assert_not_nil receipt, response.parsed_body.inspect
    child = @loop.agent_run_tasks.find_by!(node_key: receipt.fetch("task_keys").sole)
    assert_equal "model", child.authored_by
    assert_equal ["Agent"], Nexus::ToolDeclarations.names(child.tool_definitions)
    assert_equal %w[dev mock-text], [child.provider_id, child.model_ref]

    submit("delegate", { kind: "tool", name: "Agent", input: { prompt: "Check", run_in_background: false } })
    assert_response :created
    child = @loop.agent_run_tasks.find_by!(node_key: response.parsed_body.dig("operation", "receipt", "task_keys").sole)
    assert_equal %w[delegate_task Agent model], [child.tool_name, child.tool_alias, child.authored_by]
    assert_equal true, child.tool_input.fetch("wait")

    submit("broaden", { kind: "model", input: { prompt: "Review", tools: ["write_file"] } })
    assert_response :created
    assert_equal "unknown_tool_name", response.parsed_body.dig("operation", "refusal", "code")
    assert_equal 3, @loop.agent_run_tasks.count
  end

  test "a race between accepted operations observes its winner and cancels only its loser" do
    submit("a", { kind: "tool", name: "read_file", input: { path: "a" } })
    a = response.parsed_body.dig("operation", "receipt", "task_keys").sole
    submit("b", { kind: "tool", name: "read_file", input: { path: "b" } })
    b = response.parsed_body.dig("operation", "receipt", "task_keys").sole
    submit("race", { kind: "join", input: { operations: %w[a b], until: "any", losers: "cancel" } })
    assert_response :created
    assert_nil response.parsed_body.dig("operation", "refusal"), response.parsed_body.inspect
    finish(a, structured_content: { "winner" => "a" })
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    assert_equal "canceled", @loop.agent_run_tasks.find_by!(node_key: b).status
    assert_equal "dispatched", @parent.reload.status

    observations = (3..5).map do |position|
      observe(position)
      assert_response :ok
      response.parsed_body.fetch("observation")
    end
    assert_equal %w[a b race], observations.pluck("key")
    winner = observations.last.dig("outcome", "results").sole
    assert_equal a, winner.fetch("task_key")
    assert_equal({ "winner" => "a" }, winner.fetch("structured_content"))
  end

  ["any", 2, "all"].each do |mode|
    test "an all join observes the selected leaves of a nested #{mode} join" do
      keys = %w[a b c].to_h do |name|
        submit(name, { kind: "tool", name: "read_file", input: { path: name } })
        [name, response.parsed_body.dig("operation", "receipt", "task_keys").sole]
      end
      submit("inner", { kind: "join", input: { operations: keys.keys, until: mode } })
      assert_response :created
      assert_nil response.parsed_body.dig("operation", "refusal")
      submit("outer", { kind: "join", input: { operations: ["inner"], until: "all" } })
      assert_response :created
      assert_nil response.parsed_body.dig("operation", "refusal")

      finishers = { "any" => %w[c], 2 => %w[c a], "all" => %w[c a b] }.fetch(mode)
      finishers.each do |name|
        finish(keys.fetch(name), structured_content: name)
        travel 1.second
      end
      observations = (5..9).map do |position|
        observe(position)
        assert_response :ok
        response.parsed_body.fetch("observation")
      end
      assert_equal %w[a b c inner outer], observations.pluck("key")
      results = observations.last.dig("outcome", "results")
      assert_equal finishers.map { |name| keys.fetch(name) }, results.pluck("task_key")
      assert_equal finishers, results.pluck("structured_content")
    end
  end

  ["all", "any", 2].each do |mode|
    test "a #{mode} join retains failures and cancellations selected through an all join" do
      keys = %w[failed canceled completed extra loser].to_h do |name|
        submit(name, { kind: "tool", name: "read_file", input: { path: name } })
        [name, response.parsed_body.dig("operation", "receipt", "task_keys").sole]
      end
      submit("inner", { kind: "join", input: { operations: %w[failed canceled completed], until: "all" } })
      assert_response :created
      assert_nil response.parsed_body.dig("operation", "refusal")
      submit("outer", { kind: "join", input: {
        operations: mode == "all" ? ["inner"] : %w[inner extra loser], until: mode,
      } })
      assert_response :created
      assert_nil response.parsed_body.dig("operation", "refusal")
      finish(keys.fetch("failed"), structured_content: "failure detail", outcome: "failed")
      travel 1.second
      submit("cancel", { kind: "cancel", input: { operation_key: "canceled" } })
      assert_response :created
      travel 1.second
      finish(keys.fetch("completed"), structured_content: false)
      if mode == 2
        travel 1.second
        finish(keys.fetch("extra"), structured_content: "second winner")
      end
      observed = []
      position = 8
      until observed.any? { |observation| observation.fetch("key") == "outer" }
        observe(position)
        assert_response :ok
        observation = response.parsed_body.fetch("observation")
        assert_not_nil observation
        observed << observation
        position = response.parsed_body.fetch("position")
      end
      results = observed.last.dig("outcome", "results")
      selected = %w[failed canceled completed] + (mode == 2 ? ["extra"] : [])
      assert_equal selected.map { |name| keys.fetch(name) }, results.pluck("task_key")
      assert_equal %w[failed canceled completed] + (mode == 2 ? ["completed"] : []), results.pluck("status")
      assert_equal "failure detail", results.first.fetch("structured_content")
      assert_equal false, results.third.fetch("structured_content")
      assert_equal true, results.third.fetch("structured_content_present")
      inner = observed.find { |observation| observation.fetch("key") == "inner" }
      assert_equal keys.values_at("failed", "canceled", "completed"), inner.dig("outcome", "results").pluck("task_key")
    end
  end

  test "model-origin child calls cross the ordinary approval stage" do
    AgentRunTask.where(id: @parent.id).update_all(authored_by: "model")
    AgentRun.where(id: @loop.id).update_all(approval_mode: "ask")
    @loop.reload
    submit("read", { kind: "tool", name: "read_file", input: {} })
    assert_response :created
    key = response.parsed_body.dig("operation", "receipt", "task_keys").sole
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    child = @loop.agent_run_tasks.find_by!(node_key: key)
    assert_equal "model", child.authored_by
    assert_equal "needs_approval", child.status
    assert_nil child.claim_token
    assert_equal "approval_required", @loop.reload.attention_reason
  end

  test "canceling an all join observes its cancellation without freezing unfinished sources" do
    keys = %w[a b].map do |name|
      submit(name, { kind: "tool", name: "read_file", input: { path: name } })
      response.parsed_body.dig("operation", "receipt", "task_keys").sole
    end
    submit("join", { kind: "join", input: { operations: %w[a b], until: "all" } })
    joined_key = response.parsed_body.dig("operation", "receipt", "task_keys").sole
    submit("outer", { kind: "join", input: { operations: ["join"], until: "all" } })
    assert_response :created
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    submit("cancel", { kind: "cancel", input: { operation_key: "join" } })
    assert_response :created
    observe(5)
    observation = response.parsed_body.fetch("observation")
    assert_equal "join", observation.fetch("key")
    result = observation.dig("outcome", "results").sole
    assert_equal joined_key, result.fetch("task_key")
    assert_equal "canceled", result.fetch("status")
    observe(6)
    assert_equal "outer", response.parsed_body.dig("observation", "key")
    assert_equal [result], response.parsed_body.dig("observation", "outcome", "results")
    assert_equal %w[dispatched dispatched], @loop.agent_run_tasks.where(node_key: keys).order(:id).pluck(:status)
    assert_empty @parent.task_operations.where(operation_key: %w[a b]).where.not(observed_position: nil)
  end

  test "attached results stay behind the parent and background transfer releases them" do
    submit("read", { kind: "tool", name: "read_file", input: {} })
    key = response.parsed_body.dig("operation", "receipt", "task_keys").sole
    child = @loop.agent_run_tasks.find_by!(node_key: key)
    assert_equal [key], AgentRuns::Delivery.internal(@loop, [child])
    assert_empty AgentRuns::Delivery.internal(@loop, [@parent])

    submit("release", { kind: "background", input: { operation_key: "read", lifetime: "conversation", wake: "passive" } })
    assert_response :created
    assert_equal ["read"], response.parsed_body.dig("operation", "receipt", "released_operations")
    assert_predicate child.reload, :detached?
    assert_equal "passive", child.wake
    assert_empty AgentRuns::Delivery.internal(@loop, [child])
    observe(2)
    assert_equal "release", response.parsed_body.dig("observation", "key")
    assert_equal ["read"], response.parsed_body.dig("observation", "outcome", "released_operations")
    assert_nil @parent.task_operations.find_by!(operation_key: "read").observed_position
  end

  test "a queued future replacement preserves preceding history and rewrites later reads" do
    submit("plan", { kind: "steps", input: [declared_tool("a", "read_file"), declared_tool("b", "read_file"),
      { model: { key: "c", prompt: "summarize", results: ["b"] } }] })
    assert_response :created
    receipt = response.parsed_body.dig("operation", "receipt")
    a, b, c = %w[a b c].map { |name| @loop.agent_run_tasks.find_by!(node_key: receipt.fetch("keys").fetch(name)) }
    submit("revision", { kind: "replace", input: { operation_key: "plan", tasks: ["b"], steps: [declared_tool("new", "read_file")] } })
    assert_response :created
    revision = response.parsed_body.fetch("operation")
    assert_nil revision["refusal"], revision.inspect
    replacement = @loop.agent_run_tasks.find_by!(node_key: revision.dig("receipt", "keys", "new"))
    assert_equal "canceled", b.reload.status
    assert_equal "queued", a.reload.status
    assert_includes replacement.sources.pluck(:node_key), a.node_key
    assert_includes c.reload.sources.pluck(:node_key), replacement.node_key
    assert_includes c.result_from_node_keys, replacement.node_key
    refute_includes c.result_from_node_keys, b.node_key
    count = @loop.agent_run_tasks.count
    submit("revision", revision.fetch("request"))
    assert_response :ok
    assert_equal revision, response.parsed_body.fetch("operation")
    assert_equal count, @loop.agent_run_tasks.count
  end

  test "replacing a final task retains the original operation identity and returns the new result separately" do
    submit("plan", { kind: "steps", input: [declared_tool("old", "read_file")] })
    old = response.parsed_body.dig("operation", "receipt", "task_keys").sole
    submit("revision", { kind: "replace", input: {
      operation_key: "plan", tasks: ["old"], steps: [declared_tool("new", "read_file")],
    } })
    replacement = response.parsed_body.dig("operation", "receipt", "task_keys").sole
    observe(2)
    assert_equal "plan", response.parsed_body.dig("observation", "key")
    original = response.parsed_body.dig("observation", "outcome", "results").sole
    assert_equal old, original.fetch("task_key")
    assert_equal "canceled", original.fetch("status")

    finish(replacement, structured_content: "revised")
    observe(3)
    assert_equal "revision", response.parsed_body.dig("observation", "key")
    revised = response.parsed_body.dig("observation", "outcome", "results").sole
    assert_equal replacement, revised.fetch("task_key")
    assert_equal "revised", revised.fetch("structured_content")
  end

  test "replacement refuses started tasks without accepting a partial graph" do
    submit("read", { kind: "tool", name: "read_file", input: {} })
    key = response.parsed_body.dig("operation", "receipt", "task_keys").sole
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    submit("revision", { kind: "replace", input: { operation_key: "read", steps: [declared_tool("new", "read_file")] } })
    assert_response :created
    assert_equal "task_already_started", response.parsed_body.dig("operation", "refusal", "code")
    assert_equal 2, @loop.agent_run_tasks.count
    assert_equal "dispatched", @loop.agent_run_tasks.find_by!(node_key: key).status
  end

  test "sealed observations survive a later child output repair and paginate in causal order" do
    submit("read", { kind: "tool", name: "read_file", input: {} })
    key = response.parsed_body.dig("operation", "receipt", "task_keys").sole
    child = finish(key, structured_content: false)
    observe(1)
    original = response.parsed_body.fetch("observation")
    ContentBodies::Replace.call(owner: child, role: "output", entries: [{ "text" => "repair" }], seal: true)
    observe(1)
    assert_equal original, response.parsed_body.fetch("observation")
    get route("operations"), params: { limit: 1 }, headers: bearer.merge("Claim-Token" => @token)
    assert_response :ok
    assert_equal [1], response.parsed_body.dig("operations", "trace").pluck("position")
    assert_equal 1, response.parsed_body.dig("operations", "next_after")
    get route("operations"), params: { after: 1, limit: 1 }, headers: bearer.merge("Claim-Token" => @token)
    assert_equal [original], response.parsed_body.dig("operations", "trace")
    assert_nil response.parsed_body.dig("operations", "next_after")
  end

  test "observation batches readiness reads across pending widths" do
    counts = [2, 40].map do |width|
      measured = nil
      ApplicationRecord.transaction(requires_new: true) do
        width.times do |index|
          submit("pending_#{index}", { kind: "tool", name: "read_file", input: { index: index } })
          assert_response :created
        end
        observation = capture_queries { observe(width) }
        assert_response :ok
        assert_nil response.parsed_body.fetch("observation")
        measured = observation
        raise ActiveRecord::Rollback
      end
      measured
    end

    assert_equal counts.first.length, counts.last.length
    counts.each do |statements|
      assert_equal 0, statements.count { |sql| sql.include?("WITH RECURSIVE standing") },
        "unexpanded pending roots cannot yet yield a result"
    end
  end

  test "batched readiness preserves expanded results and immediate outcomes in operation order" do
    keys = %w[expanded normal waiting].to_h do |key|
      submit(key, { kind: "tool", name: "read_file", input: {} })
      assert_response :created
      [key, response.parsed_body.dig("operation", "receipt", "task_keys").sole]
    end
    submit("refused", { kind: "tool", name: "not_declared", input: {} })
    assert_response :created
    submit("background", { kind: "background", input: {
      steps: [declared_tool("detached", "read_file")], lifetime: "conversation", wake: "passive",
    } })
    assert_response :created
    assert_nil response.parsed_body.dig("operation", "refusal")

    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    expanded = @loop.agent_run_tasks.find_by!(node_key: keys.fetch("expanded"))
    append_branch!(expanded, [declared_tool("expanded-result", "read_file", "route" => { "kind" => "runner", "runner_executor_public_id" => @runner.public_id })], detached: false)
    finish(keys.fetch("normal"), structured_content: "normal")

    observe(5)
    assert_equal "normal", response.parsed_body.dig("observation", "key")
    assert_equal "normal", response.parsed_body.dig("observation", "outcome", "structured_content")

    finish("expanded-result", structured_content: "expanded value")
    observe(6)
    assert_equal "expanded", response.parsed_body.dig("observation", "key")
    assert_equal "expanded-result", response.parsed_body.dig("observation", "outcome", "task_key")
    assert_equal "expanded value", response.parsed_body.dig("observation", "outcome", "structured_content")
    observe(7)
    assert_equal "refused", response.parsed_body.dig("observation", "key")
    assert_equal "unknown_tool_name", response.parsed_body.dig("observation", "refusal", "code")
    observe(8)
    assert_equal "background", response.parsed_body.dig("observation", "key")
    assert_equal true, response.parsed_body.dig("observation", "outcome", "structured_content", "background")

    observe(9)
    assert_response :ok
    assert_nil response.parsed_body.fetch("observation")
    assert_equal "dispatched", @loop.agent_run_tasks.find_by!(node_key: keys.fetch("waiting")).status
    assert_equal @token, @parent.reload.claim_token
  end

  private

    # Child steps inherit their source declaration; only an explicit override is sent.
    def declared_tool(key, name = "shell", **over)
      { "tool" => { "key" => key, "name" => name }.merge(over) }
    end

    def capture_queries
      statements = []
      subscriber = ->(*, payload) do
        statements << payload.fetch(:sql) unless payload[:cached] || payload[:name].in?(%w[SCHEMA TRANSACTION])
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      statements
    end

    def bearer = { "Authorization" => "Bearer #{suite_runner_connection.executor_access_secret}" }
    def route(resource) = "/agent_api/v1/executor/inbox/#{@loop.public_id}/#{@parent.node_key}/#{resource}"

    def submit(key, request)
      post route("operations"), params: { claim_token: @token, operation: { key: key, request: request } }, headers: bearer, as: :json
    end

    def observe(after)
      post route("observation"), params: { claim_token: @token, after: after }, headers: bearer, as: :json
    end

    def finish(key, structured_content:, outcome: "completed")
      AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
      claimed = Executors::Claim.call(Executors::Claim::Command.new(agent_run: @loop, task_key: key, executor: @runner))
      assert_predicate claimed, :accepted?
      settled = AgentRuns::Parks::Settle.call(node: claimed.value, claim_token: claimed.value.claim_token,
        content: "child", structured_content: structured_content, outcome: outcome)
      assert_predicate settled, :applied?
      claimed.value.reload
    end
end
