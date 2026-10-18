require "test_helper"

class Runs::SpawnDeclarationsTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::SPAWN, READ_TOOL])
    @catalog = [{ "name" => "reviewer", "description" => "Review the supplied task", "model_mode" => "caller",
      "declaration" => { "default_model" => "dev/mock-priced", "fallback_models" => ["dev/mock-unmetered"],
        "system_prompt" => { "content" => "Review the task carefully." },
        "memory_context_limit" => { "bindings" => [{ "name" => "conversation", "scope" => "conversation", "access" => "read_write" }] } } }]
    @agent.update!(delegation_catalog: @catalog)
  end

  test "a selected declaration creates a same-principal child with owned configuration and caller model" do
    run = spawn!({ "declaration" => "reviewer", "prompt" => "Review this change." })
    child = child_of(run)
    assert_not_nil child
    assert_equal [@agent.id, @agent.id], [child.creating_user_id, child.answering_user_id]
    assert_equal "Review the task carefully.", child.agent_configuration.system_prompt.content
    assert_equal "dev/mock-text", child.agent_configuration.default_model
    assert_equal "inherited", child.model_selection.source
    assert_equal ["dev/mock-unmetered"], child.fallback_models
    assert_equal ["reviewer"], child.agent_configuration.delegation_catalog.map(&:name)
    brief = child.inputs.sole
    assert_equal child.agent_configuration.as_json, brief.agent_configuration.as_json
    assert_equal %w[dev mock-text], [brief.provider_id, brief.model_ref]
    assert_equal ["conversation"], child.effective_memory_context.fetch("bindings").map { |entry| entry.fetch("scope") }

    @agent.update!(delegation_catalog: [], default_model: "dev/mock-priced", memory_context_limit: nil)
    assert_equal "Review the task carefully.", child.reload.agent_configuration.system_prompt.content
    assert_equal ["conversation"], child.effective_memory_context.fetch("bindings").map { |entry| entry.fetch("scope") }
  end

  test "a declaration's default model and a task's explicit override stay distinct" do
    @catalog.first["model_mode"] = "default"
    @agent.update!(delegation_catalog: @catalog)
    child = child_of(spawn!({ "declaration" => "reviewer", "prompt" => "Review." }))
    assert_equal "dev/mock-priced", child.agent_configuration.default_model
    assert_equal "default", child.model_selection.source

    explicit = child_of(spawn!({ "declaration" => "reviewer", "prompt" => "Review again.",
      "model" => "dev/mock-text", "fallback_models" => [] }))
    assert_equal "dev/mock-text", explicit.agent_configuration.default_model
    assert_equal "explicit", explicit.model_selection.source
    assert_equal "route", explicit.model_selection.constraint
    assert_equal [], explicit.fallback_models
  end

  test "inherited tools retain the parent's exact MCP target and application schema alongside independent role tools" do
    local = declare_mcp_tools
    @catalog.first.merge!("inherited_tool_names" => %w[notes_search local_search unavailable])
    @catalog.first.fetch("declaration").merge!("tool_definitions" => [READ_TOOL], "approval_mode" => "bypass")
    @agent.update!(delegation_catalog: @catalog)

    run = spawn!({ "declaration" => "reviewer", "prompt" => "Review these notes." })
    child = child_of(run)
    assert_not_nil child
    definitions = child.agent_configuration.tool_definitions
    assert_equal %w[local_search notes_search read_file], Nexus::ToolDeclarations.names(definitions).sort
    assert_includes definitions, local
    parent_mcp = loop_node(run, "r1").tool_definitions.find { |entry| entry.dig("route", "kind") == "mcp" }
    assert_includes definitions, parent_mcp
    assert_equal @mcp_connection.public_id, parent_mcp.dig("route", "connection_public_id")
    assert_equal "search", parent_mcp.dig("route", "tool_name")
  end

  test "nested inheritance takes only the immediate parent's tools even when another role requests more" do
    declare_mcp_tools
    @catalog.first.merge!("inherited_tool_names" => %w[notes_search local_search])
    @catalog.first.fetch("declaration").merge!("tool_definitions" => [Nexus::Tools::SPAWN], "approval_mode" => "bypass")
    worker = @catalog.first.deep_dup.merge("name" => "worker", "inherited_tool_names" => ["local_search"])
    @agent.update!(delegation_catalog: [worker, *@catalog])

    child = child_of(spawn!({ "declaration" => "worker", "prompt" => "Review a local task." }))
    assert_equal %w[local_search spawn], Nexus::ToolDeclarations.names(child.agent_configuration.tool_definitions).sort
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_run = child.turns.sole.active_variant.run
    schedule_loop!(child_run)
    perform_enqueued_jobs(only: [Runs::ConversationToolJob, Runs::ScheduleJob]) do
      finish_round(child_run, "r1", sse_success("Delegate review", tool_calls: [{ id: "nested_mcp", name: "spawn",
        arguments: { declaration: "reviewer", prompt: "Review this local result." }.to_json }]))
    end
    grandchild = child_run.tasks.find_by!(tool_call_id: "nested_mcp").spawned_conversation
    assert_not_nil grandchild
    assert_equal %w[local_search spawn], Nexus::ToolDeclarations.names(grandchild.agent_configuration.tool_definitions).sort
    assert_equal child.agent_configuration.tool_definitions.find { |entry| entry.dig("function", "name") == "local_search" },
      grandchild.agent_configuration.tool_definitions.find { |entry| entry.dig("function", "name") == "local_search" }
  end

  test "caller selection follows the spawning branch's recovered model and preserves its intent and reasoning" do
    catalog = ModelCatalog.current
    models = catalog.models.deep_dup
    models.fetch("dev/mock-unmetered").fetch("capabilities")["reasoning"] = {
      "efforts" => %w[low high], "default_effort" => "high", "default_enabled" => false, "disable_supported" => true,
    }
    ModelCatalog.stub(:current, catalog.with(models: models)) do
      _turn, run = materialize_loop_reply!(@conversation, agent: @agent)
      branch_intent = { "source" => "explicit", "model" => "dev/mock-priced", "constraint" => "provider",
        "alternatives" => ["dev/mock-windowless"] }
      branch = Runs::Tasks::Append.call(Runs::Tasks::Append::Command.kernel(
        run: run,
        steps: [Runs::Tasks::Step::Model.new(key: "aside", model: { "model" => "dev/mock-priced" },
          prompt: "Review independently.", tools: [Nexus::Tools::SPAWN], model_selection: branch_intent,
          fallback_models: ["dev/mock-unmetered"])],
        tip: Runs::Tasks::Tip.seed(Runs::Tasks::Compile::BRANCH), origin: "kernel"
      ))
      assert_predicate branch, :applied?, branch.outcome.inspect
      schedule_loop!(run)
      finish_round(run, "aside", sse_refused("The provider declined this request."))
      assert_equal "mock-unmetered", loop_node(run, "aside").model_ref
      perform_enqueued_jobs(only: [Runs::ConversationToolJob, Runs::ScheduleJob]) do
        finish_round(run, "aside", sse_success("Delegating", tool_calls: [{ id: "branch_spawn", name: "spawn",
          arguments: { declaration: "reviewer", prompt: "Review the branch." }.to_json }]))
      end

      child = run.tasks.find_by!(tool_call_id: "branch_spawn").spawned_conversation
      assert_not_nil child
      assert_equal "dev/mock-unmetered", child.agent_configuration.default_model
      assert_equal branch_intent.merge("source" => "inherited"), child.model_selection.as_json
      assert_equal "mock-text", Runs::CurrentModel.for(run).model_ref
      brief = child.inputs.sole
      assert_equal ["mock-unmetered", false, "high"], brief.values_at(:model_ref, :reasoning_enabled, :reasoning_effort)
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
      variant = child.turns.sole.active_variant
      assert_equal ["mock-unmetered", false, "high"], variant.values_at(:model_ref, :reasoning_enabled, :reasoning_effort)
      assert_equal branch_intent.merge("source" => "inherited"), variant.model_selection.as_json
    end
  end

  test "a declaration without a default requires a task model and creates no partial child" do
    @catalog.first["model_mode"] = "default"
    @catalog.first.fetch("declaration")["default_model"] = nil
    @agent.update!(delegation_catalog: @catalog)

    run = spawn!({ "declaration" => "reviewer", "prompt" => "Review." })
    assert_nil child_of(run)
    assert_includes output_of(run), "model is required"
    assert_equal "completed", loop_node(run, "r2t0").status
    explicit = child_of(spawn!({ "declaration" => "reviewer", "prompt" => "Review again.", "model" => "dev/mock-text" }))
    assert_equal "dev/mock-text", explicit.agent_configuration.default_model
    assert_equal "explicit", explicit.model_selection.source
  end

  test "a catalog requires a listed declaration and refuses identity shortcuts" do
    [{}, { "agent" => @agent.public_id }, { "declaration" => "missing" },
      { "declaration" => "reviewer", "agent" => @agent.public_id }].each do |fields|
      run = spawn!(fields.merge("prompt" => "Review."))
      assert_nil child_of(run)
      assert_includes output_of(run), "reviewer"
      Conversations::Turns::Cancel.stop_tree(run.conversation)
    end
    @agent.update!(delegation_catalog: [])
    run = spawn!({ "prompt" => "Review." })
    assert_nil child_of(run)
    assert_includes output_of(run), "no declarations"
  end

  test "nested spawn keeps its captured catalog after publication is withdrawn and follows the immediate caller" do
    @catalog.first.fetch("declaration").merge!("tool_definitions" => [Nexus::Tools::SPAWN], "approval_mode" => "bypass")
    @agent.update!(delegation_catalog: @catalog)
    parent = spawn!({ "declaration" => "reviewer", "prompt" => "Review.", "model" => "dev/mock-priced" })
    child = child_of(parent)
    @agent.update!(delegation_catalog: [], default_model: "dev/mock-windowless")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_run = child.turns.sole.active_variant.run
    assert_equal %w[spawn], Nexus::ToolDeclarations.names(loop_node(child_run, "r1").tool_definitions)
    schedule_loop!(child_run)

    assert_no_difference -> { User.count } do
      perform_enqueued_jobs(only: [Runs::ConversationToolJob, Runs::ScheduleJob]) do
        finish_round(child_run, "r1", sse_success("Delegate one part", tool_calls: [{ id: "nested_spawn", name: "spawn",
          arguments: { declaration: "reviewer", prompt: "Review this part." }.to_json }]))
      end
    end
    grandchild = child_run.tasks.find_by!(tool_call_id: "nested_spawn").spawned_conversation
    assert_not_nil grandchild
    assert_equal child.public_id, grandchild.parent_conversation_public_id
    assert_equal @agent, grandchild.answering_user
    assert_equal "dev/mock-priced", grandchild.agent_configuration.default_model
    assert_equal "route", grandchild.model_selection.constraint
    assert_equal "inherited", grandchild.model_selection.source
    assert_equal ["reviewer"], grandchild.agent_configuration.delegation_catalog.map(&:name)
    assert_equal ["conversation"], grandchild.effective_memory_context.fetch("bindings").map { |entry| entry.fetch("scope") }

    fresh = spawn!({ "declaration" => "reviewer", "prompt" => "New independent request." })
    assert_nil child_of(fresh)
    assert_includes output_of(fresh), "no declarations"
  end

  test "a fork of a declared child keeps its defaults without a spawn marker" do
    parent = spawn!({ "declaration" => "reviewer", "prompt" => "Review." })
    child = child_of(parent)
    turn = complete_child(child)
    forked = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: child.reload, turn_public_id: turn.public_id, variant_public_id: turn.active_variant.public_id,
      acting_user: @human, title: "Continue separately"
    ))
    assert_predicate forked, :accepted?, forked.outcome.inspect
    fork = forked.value
    assert_not_predicate fork, :subagent?
    assert_equal true, AgentAPI::ConversationPresenter.full(fork, acting_user: @human).fetch(:agent_configuration_present)
    assert_equal child.agent_configuration.as_json, fork.agent_configuration.as_json
    assert_equal child.model_selection, fork.model_selection
    assert_equal child.fallback_models, fork.fallback_models
    @agent.update!(delegation_catalog: [], default_model: "dev/mock-priced", memory_context_limit: nil)
    input = child_input(fork)
    assert_equal "Review the task carefully.", input.agent_configuration.system_prompt.content
    assert_equal "mock-text", input.model_ref
    assert_equal ["conversation"], input.execution_memory_context.fetch("bindings").map { |entry| entry.fetch("scope") }
  end

  test "a declared child's tools skills and provider scope exclude private roots and other conversation aliases" do
    shared = Conversation.create!(workspace: @workspace, creating_user: @human)
    configuration = { "bindings" => MemoryContext::DEFAULT.bindings.map { |binding| binding.to_h.transform_values { |value| value&.to_s }.compact.stringify_keys } + [
      { "name" => "group", "scope" => "conversation", "access" => "read_write", "conversation_public_id" => shared.public_id },
    ] }
    @conversation.update!(memory_context: configuration)
    foreign = Conversations::Memory::Apply.write(conversation: shared, by: @human, path: "conversation/private.md",
      content: "Another task's fact", expected: nil)
    assert_predicate foreign, :accepted?
    workspace_skill = MemoryDocuments::Write.call(anchor: Scopes::Anchor.call(path: "workspace/skills/private-guide", workspace: @workspace),
      content: "Workspace guide", description: "Private workspace guidance", expected: nil)
    assert_predicate workspace_skill, :written?
    @catalog.first.fetch("declaration").merge!(
      "kernel_tools" => %w[nexus.memory.read nexus.memory.write nexus.skill.load], "approval_mode" => "bypass")
    @agent.update!(delegation_catalog: @catalog)
    parent = spawn!({ "declaration" => "reviewer", "prompt" => "Review." }, conversation: @conversation)
    child = child_of(parent)
    @agent.update!(memory_context_limit: nil, delegation_catalog: [])
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    run = child.turns.sole.active_variant.run
    round = loop_node(run, "r1")
    assert_equal ["conversation"], run.memory_context.fetch("bindings").map { |binding| binding.fetch("scope") }
    assert_empty round.operation_context.fetch("environment").fetch("skills")
    assert_not_includes round.input_body.effective_text, "Another task's fact"
    assert_not_includes round.input_body.effective_text, "Private workspace guidance"
    schedule_loop!(run)

    calls = [
      { id: "foreign_read", name: "memory_read", arguments: { path: "group/private.md" }.to_json },
      { id: "private_write", name: "memory_write", arguments: { path: "agent/new.md", content: "Wrong scope" }.to_json },
      { id: "own_write", name: "memory_write", arguments: { path: "conversation/result.md", content: "Review result" }.to_json },
    ]
    perform_enqueued_jobs(only: [Runs::MemoryJob, Runs::ScheduleJob]) do
      finish_round(run, "r1", sse_success("Use only my task memory", tool_calls: calls))
    end
    %w[foreign_read private_write].each do |id|
      call = run.tasks.find_by!(tool_call_id: id)
      assert call.output_summary.fetch("is_error")
      assert_includes call.output_body.effective_text, "memory_scope_unavailable"
      scope = Executors::Inbox.scope_of(call).fetch(:bindings)
      assert_equal [child.public_id], scope.map { |binding| binding.fetch(:conversation_public_id) }
    end
    own = run.tasks.find_by!(tool_call_id: "own_write")
    assert_not own.output_summary["is_error"]
    assert_equal "Review result", child.memory_documents.find_by!(name: "result.md").content
    assert_not MemoryDocument.for_user(@agent.id).exists?(name: "new.md")
  end

  test "later input and preview keep child defaults after source details and the first input are reaped" do
    parent = spawn!({ "declaration" => "reviewer", "prompt" => "Review." })
    child = child_of(parent)
    run_loop_round!(parent, sse_success("Review requested."))
    Conversations::Turns::Converge.call
    complete_child(child)
    assert_empty child.inputs
    parent.with_lock { Runs::Reap.destroy_details(parent) }
    assert_nil child.reload.spawn_node_id
    @agent.update!(delegation_catalog: [], default_model: "dev/mock-priced", memory_context_limit: nil)

    accepted = child_input(child)
    assert_equal "dev/mock-text", accepted.agent_configuration.default_model
    assert_equal %w[dev mock-text], [accepted.provider_id, accepted.model_ref]
    assert_equal "inherited", accepted.model_selection.source
    assert_equal ["dev/mock-unmetered"], accepted.fallback_models
    assert_equal ["conversation"], accepted.execution_memory_context.fetch("bindings").map { |entry| entry.fetch("scope") }
    assert_equal true, AgentAPI::ConversationPresenter.full(child, acting_user: @agent).fetch(:agent_configuration_present)

    estimate = Conversations::ContextEstimate.call(Conversations::ContextEstimate::Command.new(
      conversation: child, acting_user: @agent, provider_id: nil, model_ref: nil, reasoning_effort: nil,
      request_options: nil, prompt: "Continue the review.", history_max_entries: nil,
      history_token_budget_share: nil, reasoning_replay_mode: nil, inline: nil, render: true
    ))
    assert_predicate estimate, :accepted?, estimate.outcome.inspect
    assert_equal "mock-text", estimate.value.selection.model_ref
    assert_includes estimate.value.rendered.entries.to_json, "Review the task carefully."
  end

  test "a child's recovered current model survives execution detail retention for future input and preview" do
    @catalog.first.fetch("declaration").merge!("kernel_tools" => ["nexus.memory.read"], "approval_mode" => "bypass")
    @agent.update!(delegation_catalog: @catalog)
    parent = spawn!({ "declaration" => "reviewer", "prompt" => "Review." })
    child = child_of(parent)
    run_loop_round!(parent, sse_success("Review requested."))
    Conversations::Turns::Converge.call
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    turn = child.turns.sole
    run = turn.active_variant.run
    schedule_loop!(run)
    finish_round(run, "r1", sse_refused("The provider declined this request."))
    assert_equal "mock-unmetered", Runs::CurrentModel.for(run).model_ref
    finish_round(run, "r1", sse_success("Reviewed."))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    run.update!(completed_at: 100.days.ago)
    @account.update!(execution_details_retention_days: 90)

    assert_equal 1, Conversations::ExecutionDetails::Prune.call(account: @account, batch: 20)[:pruned]
    assert_empty run.tasks.reload
    assert_equal "mock-text", turn.active_variant.reload.model_ref, "the initial route stays immutable"
    assert_equal "mock-unmetered", Runs::CurrentModel.for_variant(turn.active_variant).model_ref
    assert_equal "mock-unmetered", Runs::CurrentModel.for_loops([run.reload]).fetch(run.id).model_ref
    projected = Conversations::TurnProjection.turn_snapshot(turn)
    assert_equal "mock-unmetered", projected.fetch(:active_variant).fetch(:model).fetch(:model_ref)
    input = child_input(child)
    assert_equal "mock-unmetered", input.model_ref
    assert_equal "dev/mock-text", input.model_selection.model
    assert_equal "inherited", input.model_selection.source

    estimate = Conversations::ContextEstimate.call(Conversations::ContextEstimate::Command.new(
      conversation: child, acting_user: @agent, provider_id: nil, model_ref: nil, reasoning_effort: nil,
      request_options: nil, prompt: "Continue the review.", history_max_entries: nil,
      history_token_budget_share: nil, reasoning_replay_mode: nil, inline: nil
    ))
    assert_predicate estimate, :accepted?, estimate.outcome.inspect
    assert_equal "mock-unmetered", estimate.value.selection.model_ref
  end

  test "a direct child's fallback variant retains its actual model after invocation collection" do
    parent = spawn!({ "declaration" => "reviewer", "prompt" => "Review." })
    child = child_of(parent)
    run_loop_round!(parent, sse_success("Review requested."))
    Conversations::Turns::Converge.call
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    turn = child.turns.sole
    ModelInvocations::AdmitQueuedWork.call
    apply_via(turn.active_variant.model_invocation.attempts.last, sse_refused("The provider declined this request."))
    Conversations::Turns::Converge.call
    fallback = turn.variants.order(:position).last
    assert_equal "fallback", fallback.source
    assert_equal "mock-unmetered", fallback.model_ref
    ModelInvocations::AdmitQueuedWork.call
    apply_via(fallback.model_invocation.attempts.last, sse_success("Reviewed."))
    Conversations::Turns::Converge.call
    assert_equal fallback, turn.reload.active_variant
    fallback.model_invocation.update!(terminal_at: 100.days.ago)
    @account.update!(execution_details_retention_days: 90)

    assert_equal 1, Conversations::ExecutionDetails::Prune.call(account: @account, batch: 20, kind: "invocations")[:pruned]
    assert_nil fallback.reload.model_invocation_id
    assert_equal "mock-unmetered", Runs::CurrentModel.for_variant(fallback).model_ref
    input = child_input(child)
    assert_equal "mock-unmetered", input.model_ref
    assert_equal "dev/mock-text", input.model_selection.model
  end

  private

    def declare_mcp_tools
      @mcp_connection = @agent.steward.mcp_connections.create!(name: "Inherited notes", endpoint_url: "https://notes.example.test/mcp",
        auth_type: "none", catalog: mcp_connections(:notes).tools_catalog)
      local = { "type" => "function", "function" => { "name" => "local_search", "description" => "Search the local MCP",
        "parameters" => { "type" => "object", "properties" => { "query" => { "type" => "string" } } } } }
      declare_tools!(@agent, tools: [Nexus::Tools::SPAWN, local])
      @agent.update!(mcp_tools: [{ "connection_public_id" => @mcp_connection.public_id, "tool_name" => "search", "name" => "notes_search" }])
      local
    end

    def child_input(child, **options)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: child, acting_user: @agent, kind: "direct_reply", role: "user",
        entries: [{ "text" => "Continue the review." }], visible_in_context: true, delivery_mode: "queue",
        context_mode: nil, context_options: nil, expected_context_revision: nil, expected_tail_turn_public_id: nil,
        provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil, **options
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
      result.value
    end

    def finish_round(run, key, response)
      round = loop_node(run, key)
      ModelInvocations::AdmitQueuedWork.call
      apply_via(round.selected_model_invocation.attempts.order(:id).last, response)
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      schedule_loop!(run)
    end

    def complete_child(child)
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
      turn = child.turns.order(:position).last
      ModelInvocations::AdmitQueuedWork.call
      apply_via(turn.active_variant.model_invocation.attempts.last, sse_success("Reviewed."))
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      turn
    end

    def spawn!(input, conversation: nil)
      conversation ||= Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
      post_input!(conversation, acting_user: @human, text: "Delegate this task.")
      _turn, run = materialize_loop_reply!(conversation, agent: @agent, text: nil)
      schedule_loop!(run)
      invocation = loop_node(run, "r1").selected_model_invocation
      ModelInvocations::AdmitQueuedWork.call
      apply_via(invocation.attempts.order(:id).last,
        sse_success("Delegating", tool_calls: [{ id: "spawn_call", name: "spawn", arguments: input.to_json }]))
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [Runs::ConversationToolJob, Runs::ScheduleJob]) do
        Runs::ScheduleReady.call(run_id: run.id)
      end
      run.reload
    end

    def child_of(run) = Conversation.find_by(spawn_node_id: loop_node(run, "r2t0").id)
    def output_of(run) = loop_node(run, "r2t0").content_bodies.find_by(role: "output").effective_text
end
