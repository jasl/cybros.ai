require "test_helper"

class AgentRuns::ToolDiscoveryTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "search returns exact frozen schemas and targets while provider tools stay stable" do
    first = declaration("local_read", suite_runner)
    second = declaration("remote_read", runner_b).deep_merge("function" => {
      "parameters" => { "required" => %w[path encoding], "properties" => { "encoding" => { "enum" => %w[utf8 ascii] } } },
    })
    run = execution([first, second])
    round = loop_node(run, "round1")
    assert_equal %w[tool_call tool_search], wire_names(round)
    frozen = round.tool_definitions.deep_dup
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: run, acting_user: @human))
    run_loop_round!(run, sse_success("find", tool_calls: [
      { id: "search", name: "tool_search", arguments: { query: "#{runner_b.public_id} read" }.to_json },
    ]))
    assert_predicate Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
      host: run, executor_public_id: runner_b.public_id, acting_user: @human)), :accepted?
    runner_b.announce(tools: [])
    wrapper = loop_node(run, "r1t0")
    AgentRuns::ToolDiscoveryJob.perform_now(wrapper.id)
    result = JSON.parse(wrapper.reload.output_body.effective_text)
    item = result.fetch("tools").sole
    assert_equal "remote_read", item.fetch("name")
    assert_equal second.fetch("function").fetch("parameters"), item.dig("definition", "function", "parameters")
    assert_equal second.fetch("route"), item.fetch("route")
    assert_equal [], item.fetch("skills")
    assert_equal false, result.fetch("truncated")
    assert_equal frozen, round.reload.tool_definitions
    schedule_loop!(run)
    assert_equal round.selected_model_invocation.request_options.fetch("tools"),
      loop_node(run, "r1").selected_model_invocation.request_options.fetch("tools")
  end

  test "deferred catalog additions do not alter the provider tool prefix" do
    first = execution([declaration("local_read", suite_runner)])
    second = execution([declaration("local_read", suite_runner), declaration("remote_read", runner_b)])
    assert_equal loop_node(first, "round1").selected_model_invocation.request_options.fetch("tools"),
      loop_node(second, "round1").selected_model_invocation.request_options.fetch("tools")
  end

  test "search uses frozen skill summaries and can match a target plus a skill name" do
    runner = runner_b
    runner.announce(tools: [{ "name" => "skill", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }],
      documents: [{ "name" => "database-tuning", "description" => "Optimize PostgreSQL queries" }])
    skill = declaration("remote_skill", runner, served: "skill")
    run = execution([skill])
    run_loop_round!(run, sse_success("find", tool_calls: [
      { id: "search", name: "tool_search", arguments: { query: "#{runner.public_id} PostgreSQL" }.to_json },
    ]))
    runner.announce(tools: [], documents: [])
    wrapper = loop_node(run, "r1t0")
    AgentRuns::ToolDiscoveryJob.perform_now(wrapper.id)
    item = JSON.parse(wrapper.reload.output_body.effective_text).fetch("tools").sole
    assert_equal "remote_skill", item.fetch("name")
    assert_equal "database-tuning", item.fetch("skills").sole.fetch("name")
    assert_equal runner.public_id, item.fetch("skills").sole.fetch("executor_public_id")
  end

  test "zero to one frozen skills leaves deferred provider tools unchanged" do
    runner = runner_b
    skill_tool = { "name" => "skill", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }
    runner.announce(tools: [skill_tool], documents: [])
    skill = declaration("remote_skill", runner, served: "skill")
    empty = execution([skill, Nexus::Tools::SKILL.merge("defer_loading" => true)])
    runner.announce(tools: [skill_tool], documents: [{ "name" => "deploy", "description" => "Ship the project" }])
    populated = execution([skill, Nexus::Tools::SKILL.merge("defer_loading" => true)])
    first = loop_node(empty, "round1")
    second = loop_node(populated, "round1")
    assert_empty first.operation_context.dig("environment", "skills")
    assert_equal "deploy", second.operation_context.dig("environment", "skills").sole.fetch("name")
    assert_equal first.selected_model_invocation.request_options.fetch("tools"),
      second.selected_model_invocation.request_options.fetch("tools")
    fallback = seed(model("round1", "tools" => [skill]))
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: fallback, acting_user: @human))
    schedule_loop!(fallback)
    assert_equal ["remote_skill"], wire_names(loop_node(fallback, "round1"))
  end

  test "search finds flat descriptions and exact names ahead of substring matches" do
    flat = { "type" => "function", "name" => "flat_reader", "description" => "Inspect lunar samples",
      "parameters" => { "type" => "object" }, "defer_loading" => true }
    run = execution([flat])
    run_loop_round!(run, sse_success("find", tool_calls: [
      { id: "description", name: "tool_search", arguments: { query: "lunar samples" }.to_json },
      { id: "exact", name: "tool_search", arguments: { query: "tool_call" }.to_json },
      { id: "fraction", name: "tool_search", arguments: { query: "lunar", limit: 2.5 }.to_json },
    ]))
    %w[r1t0 r1t1 r1t2].each { |key| AgentRuns::ToolDiscoveryJob.perform_now(loop_node(run, key).id) }
    found = JSON.parse(loop_node(run, "r1t0").output_body.effective_text).fetch("tools").sole
    assert_equal "flat_reader", found.fetch("name")
    assert_equal flat.except("defer_loading").merge("strict" => false), found.fetch("definition")
    assert_equal "tool_call", JSON.parse(loop_node(run, "r1t1").output_body.effective_text).fetch("tools").sole.fetch("name")
    assert loop_node(run, "r1t2").output_summary.fetch("is_error")
  end

  test "search bounds result count and storage without slicing a schema" do
    first = declaration("first_read", suite_runner)
    large = declaration("large_read", suite_runner).deep_merge("function" => { "description" => '"' * 400_000 })
    run = execution([first, large])
    run_loop_round!(run, sse_success("find", tool_calls: [
      { id: "count", name: "tool_search", arguments: { query: "read", limit: 1 }.to_json },
      { id: "bytes", name: "tool_search", arguments: { query: "large_read" }.to_json },
    ]))
    %w[r1t0 r1t1].each { |key| AgentRuns::ToolDiscoveryJob.perform_now(loop_node(run, key).id) }
    count = JSON.parse(loop_node(run, "r1t0").output_body.effective_text)
    assert count.fetch("truncated")
    assert_equal first.fetch("function").fetch("parameters"), count.fetch("tools").sole.dig("definition", "function", "parameters")
    bytes = JSON.parse(loop_node(run, "r1t1").output_body.effective_text)
    assert bytes.fetch("truncated")
    assert_empty bytes.fetch("tools"), "an oversized schema is omitted whole, never changed"
    assert_not loop_node(run, "r1t1").output_summary["is_error"]
  end

  test "tool_call preserves routing and full inherited authority and pairs the real error and captures" do
    run = execution([declaration("local_read", suite_runner), declaration("remote_read", runner_b)])
    run_loop_round!(run, sse_success("read", tool_calls: [
      { id: "invoke", name: "tool_call", arguments: { name: "local_read", input: { path: "a" } }.to_json },
    ]))
    wrapper = loop_node(run, "r1t0")
    AgentRuns::ToolDiscoveryJob.perform_now(wrapper.id)
    child = loop_node(run, "r1t0-tool-1")
    schedule_loop!(run)
    assert_equal "queued", loop_node(run, "r1").status
    assert_equal ["read_file", "local_read", suite_runner.public_id, "model"],
      child.reload.values_at(:tool_name, :tool_alias, :target_executor_public_id, :authored_by)
    assert_equal loop_node(run, "round1").tool_definitions,
      Executors::TaskOperations::Context.defaults(child).fetch("tools")
    assert_no_difference -> { run.agent_run_tasks.count } do
      AgentRuns::ToolDiscoveryJob.perform_now(wrapper.id)
    end
    picture = capture
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: run, task_key: child.node_key, executor: suite_runner))
    assert_predicate claimed, :accepted?
    committed = Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: run, task_key: child.node_key, executor: suite_runner, claim_token: claimed.value.claim_token,
      content: [{ "type" => "text", "text" => "The read failed after capturing the screen." },
        { "type" => "resource_link", "uri" => "nexus://uploads/#{picture.public_id}", "name" => "capture.png" }],
      structured_content: { "exit_code" => 1 }, result_type: nil, outcome: "completed", is_error: true,
      title: nil, metadata: nil))
    assert_predicate committed, :applied?
    schedule_loop!(run)
    continuation = loop_node(run, "r1")
    assert_equal "running", continuation.status, continuation.attributes.slice("error_key", "error_detail").inspect
    replay = AgentRuns::InputComposition.call(node: continuation, input: continuation.input_value)
    result = Nexus::InputEntries.for(replay.elements).find { |item| item["type"] == "tool_result_item" }.fetch("payload")
    assert result.fetch("is_error")
    assert_includes result.fetch("output"), "The read failed after capturing the screen."
    assert_equal [picture.public_id], replay.uploads.map(&:public_id)
    assert_equal child.id, AgentRuns::BranchClosure.tips_by_call_key([wrapper]).values.sole.id

    AgentRunTask.where(id: continuation.id).update_all(compaction: { "pruned_before" => continuation.node_key })
    cleared = AgentRuns::InputComposition.call(node: continuation.reload, input: continuation.input_value)
    assert_predicate cleared, :composed?
    assert_empty cleared.uploads
    cleared_result = Nexus::InputEntries.for(cleared.elements).find { |item| item["type"] == "tool_result_item" }.fetch("payload")
    assert_equal AgentRuns::RoundReplay::Pairing::CLEARED, cleared_result.fetch("output")
  end

  test "allowing tool_call does not bypass denial or approval of the actual tool" do
    %w[deny ask].each do |verdict|
      run = execution([declaration("local_read", suite_runner)], approval_mode: "rules", approval_rules: [
        { "tool" => "tool_call", "verdict" => "allow" }, { "tool" => "read_file", "verdict" => verdict },
      ])
      run_loop_round!(run, sse_success("read", tool_calls: [
        { id: "invoke", name: "tool_call", arguments: { name: "local_read", input: { path: "a" } }.to_json },
      ]))
      AgentRuns::ToolDiscoveryJob.perform_now(loop_node(run, "r1t0").id)
      schedule_loop!(run)
      child = loop_node(run, "r1t0-tool-1")
      assert_equal verdict == "deny" ? "failed" : "needs_approval", child.status
      assert_equal "approval_denied", child.error_key if verdict == "deny"
      assert_nil child.claimed_at
    end
  end

  test "a nested tool_call retains the outer call's real paired result" do
    run = execution([declaration("local_read", suite_runner)])
    run_loop_round!(run, sse_success("find", tool_calls: [
      { id: "invoke", name: "tool_call", arguments: { name: "tool_call",
        input: { name: "tool_search", input: { query: "local_read" } } }.to_json },
    ]))
    %w[r1t0 r1t0-tool-1 r1t0-tool-1-tool-1].each do |key|
      AgentRuns::ToolDiscoveryJob.perform_now(loop_node(run, key).id)
      schedule_loop!(run)
    end
    continuation = loop_node(run, "r1")
    assert_equal "running", continuation.status
    replay = AgentRuns::InputComposition.call(node: continuation, input: continuation.input_value)
    result = Nexus::InputEntries.for(replay.elements).select { |item| item["type"] == "tool_result_item" }.sole.fetch("payload")
    assert_equal "invoke", result.fetch("call_id")
    assert_equal "local_read", JSON.parse(result.fetch("output")).fetch("tools").sole.fetch("name")
    assert_equal "r1t0-tool-1-tool-1", AgentRuns::BranchClosure.tips_by_call_key([loop_node(run, "r1t0")]).values.sole.node_key
  end

  test "a wrapped operation owner pairs its final value while retaining its claim and never its internal leaf" do
    runner = suite_runner
    runner.announce(tools: TEST_SERVED_TOOLS + [{ "name" => "program",
      "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }])
    run = execution([declaration("local_program", runner, served: "program"), declaration("local_read", runner)])
    run_loop_round!(run, sse_success("run", tool_calls: [
      { id: "invoke", name: "tool_call", arguments: { name: "local_program", input: {} }.to_json },
    ]))
    wrapper = loop_node(run, "r1t0")
    AgentRuns::ToolDiscoveryJob.perform_now(wrapper.id)
    schedule_loop!(run)
    program = loop_node(run, "r1t0-tool-1")
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: run, task_key: program.node_key, executor: runner))
    assert_predicate claimed, :accepted?
    access = Executors::TaskOperations::Access.new(agent_run: run, task_key: program.node_key,
      executor: runner, claim_token: claimed.value.claim_token)
    submitted = Executors::TaskOperations::Submit.new(access: access, key: "read", request: {
      "kind" => "tool", "name" => "local_read", "input" => { "path" => "a" },
    }).call
    assert_predicate submitted, :accepted?
    child_key = submitted.value.dig("operation", "receipt", "task_keys").sole
    waiting = Executors::TaskOperations::Observe.new(access: access, after: 1).call
    assert_predicate waiting, :accepted?
    assert_nil waiting.value.fetch("observation")
    schedule_loop!(run)
    assert_equal "dispatched", program.reload.status
    assert_predicate program, :operation_owner?
    assert_equal "queued", loop_node(run, "r1").status
    internal = loop_node(run, child_key)
    assert_equal child_key, AgentRuns::TaskResultEnvelope.call_key(internal), "the program owns its internal result boundary"
    assert_predicate AgentRuns::Parks::Settle.call(node: internal, trusted: true, content: "internal leaf"), :applied?
    schedule_loop!(run)
    assert_equal "queued", loop_node(run, "r1").status
    assert_equal claimed.value.claim_token, program.reload.claim_token
    observed = Executors::TaskOperations::Observe.new(access: access, after: 1).call
    assert_predicate observed, :accepted?
    assert_equal "internal leaf", observed.value.dig("observation", "outcome", "output")
    assert_predicate AgentRuns::Parks::Settle.call(node: program, claim_token: program.claim_token,
      content: "selected program result"), :applied?
    schedule_loop!(run)
    continuation = loop_node(run, "r1")
    assert_equal "running", continuation.status
    replay = AgentRuns::InputComposition.call(node: continuation, input: continuation.input_value)
    results = Nexus::InputEntries.for(replay.elements).select { |item| item["type"] == "tool_result_item" }
    assert_equal ["selected program result"], results.map { |item| item.dig("payload", "output") }
    assert_equal program.id, AgentRuns::BranchClosure.tips_by_call_key([wrapper]).values.sole.id
  end

  test "a wrapped operation owner observes a refused child under the original claim" do
    runner = suite_runner
    runner.announce(tools: TEST_SERVED_TOOLS + [{ "name" => "program",
      "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }])
    run = execution([declaration("local_program", runner, served: "program"), declaration("local_read", runner)],
      approval_rules: [{ "tool" => "read_file", "verdict" => "deny", "reason" => "declared refusal" }])
    run_loop_round!(run, sse_success("run", tool_calls: [
      { id: "invoke", name: "tool_call", arguments: { name: "local_program", input: {} }.to_json },
    ]))
    AgentRuns::ToolDiscoveryJob.perform_now(loop_node(run, "r1t0").id)
    schedule_loop!(run)
    program = loop_node(run, "r1t0-tool-1")
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: run, task_key: program.node_key, executor: runner))
    assert_predicate claimed, :accepted?
    access = Executors::TaskOperations::Access.new(agent_run: run, task_key: program.node_key,
      executor: runner, claim_token: claimed.value.claim_token)
    submitted = Executors::TaskOperations::Submit.new(access: access, key: "read", request: {
      "kind" => "tool", "name" => "local_read", "input" => { "path" => "a" },
    }).call
    assert_predicate submitted, :accepted?
    child = loop_node(run, submitted.value.dig("operation", "receipt", "task_keys").sole)
    assert_equal "queued", child.status
    assert_equal "dispatched", program.reload.status

    AgentRuns::ScheduleReady.call(agent_run_id: run.id)

    assert_equal %w[failed approval_denied], child.reload.values_at(:status, :error_key)
    assert_equal "declared refusal", child.error_detail
    assert_nil child.claimed_at
    assert_equal "queued", loop_node(run, "r1").status, "the model still waits for the program's own result"
    assert_equal "dispatched", program.reload.status
    assert_equal 0, program.execution_generation
    assert_equal claimed.value.claim_token, program.claim_token
    observed = Executors::TaskOperations::Observe.new(access: access, after: 1).call
    assert_predicate observed, :accepted?
    assert_equal "approval_denied", observed.value.dig("observation", "outcome", "error", "key")
  end

  test "wrapped ask and waited delegation preserve their graph results in live and historical pairing" do
    run = execution([Nexus::ToolRegistry.function_definition("ask"), Nexus::ToolRegistry.function_definition("delegate_task")])
    run_loop_round!(run, sse_success("ask and delegate", tool_calls: [
      { id: "question", name: "tool_call", arguments: { name: "ask", input: { prompt: "Which file?" } }.to_json },
      { id: "delegate", name: "tool_call", arguments: { name: "delegate_task", input: { prompt: "Summarize this", wait: true } }.to_json },
    ]))
    %w[r1t0 r1t1].each { |key| AgentRuns::ToolDiscoveryJob.perform_now(loop_node(run, key).id) }
    schedule_loop!(run)
    AgentRuns::AskJob.perform_now(loop_node(run, "r1t0-tool-1").id)
    AgentRuns::DelegateTaskToolJob.perform_now(loop_node(run, "r1t1-tool-1").id)
    schedule_loop!(run)
    answer = loop_node(run, "r1t0-tool-1-ask-1")
    assert_predicate AgentRuns::Parks::Settle.call(node: answer, trusted: true, content: "README.md"), :applied?
    branch = loop_node(run, "r1t1-tool-1-model-1")
    assert_equal "running", branch.status
    run_loop_round!(run, sse_success("Delegated answer"))
    continuation = loop_node(run, "r1")
    assert_equal "running", continuation.status
    replay = AgentRuns::InputComposition.call(node: continuation, input: continuation.input_value)
    results = Nexus::InputEntries.for(replay.elements).select { |item| item["type"] == "tool_result_item" }
    assert_equal ["README.md", "Mock: Delegated answer"], results.map { |item| item.dig("payload", "output") }
    calls = %w[r1t0 r1t1].map { |key| loop_node(run, key) }
    tips = AgentRuns::BranchClosure.tips_by_call_key(calls)
    assert_equal [answer.id, branch.id], calls.map { |call| tips.fetch([run.id, call.node_key]).id }
  end

  test "undeclared calls return errors without creating children and invalid searches settle" do
    run = execution([])
    run_loop_round!(run, sse_success("find", tool_calls: [
      { id: "search", name: "tool_search", arguments: { query: "code" }.to_json },
      { id: "invoke", name: "tool_call", arguments: { name: "code", input: {} }.to_json },
      { id: "invalid", name: "tool_search", arguments: { query: "tools", limit: 21 }.to_json },
    ]))
    %w[r1t0 r1t1 r1t2].each { |key| AgentRuns::ToolDiscoveryJob.perform_now(loop_node(run, key).id) }
    assert_equal [], JSON.parse(loop_node(run, "r1t0").output_body.effective_text).fetch("tools")
    assert_match(/unknown_tool_name/, loop_node(run, "r1t1").output_body.effective_text)
    assert loop_node(run, "r1t1").output_summary.fetch("is_error")
    assert_match(/parameter_invalid/, loop_node(run, "r1t2").output_body.effective_text)
    assert_not run.agent_run_tasks.exists?(node_key: "r1t1-tool-1")
  end

  private

    def runner_b
      @runner_b ||= connect_runner(manager: users(:owner), registration_identifier: "discovery-b",
        display_name: "Build", assignment_scope: :account_wide).executor_access_token.task_executor.tap do |runner|
        runner.announce(tools: [{ "name" => "read_file", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }])
      end
    end

    def declaration(name, runner, served: "read_file")
      { "type" => "function", "defer_loading" => true,
        "function" => { "name" => name, "description" => "Read exactly this environment",
          "parameters" => { "type" => "object", "properties" => { "path" => { "type" => "string" } },
            "required" => ["path"], "additionalProperties" => false } },
        "route" => { "kind" => "runner", "runner_executor_public_id" => runner.public_id, "tool_name" => served } }
    end

    def execution(tools, **options)
      pair = %w[tool_search tool_call].map { |name| Nexus::ToolRegistry.function_definition(name) }
      run = seed(model("round1", "tools" => [*pair, *tools]), **options)
      started = AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: run, acting_user: @human))
      assert_predicate started, :accepted?
      schedule_loop!(run)
      run
    end

    def wire_names(round)
      Nexus::ToolDeclarations.names(round.selected_model_invocation.request_options.fetch("tools"))
    end

    def capture
      Tempfile.create(["tool-discovery-capture", ".png"], binmode: true) do |file|
        file.write(PngFixture.bytes(width: 1, height: 1, rgb: "\xff\x00\x00".b))
        file.flush
        upload = Rack::Test::UploadedFile.new(file.path, "image/png", original_filename: "capture.png")
        result = ContentUploads::Create.call(account: @account, creator: suite_runner, file: upload)
        assert_predicate result, :accepted?
        result.upload
      end
    end
end
