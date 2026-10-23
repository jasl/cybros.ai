require "test_helper"

class Conversations::AgentConfigurationTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  test "two accepted declarations keep independent prompts tools and memory permissions under one real principal" do
    first = declaration("Read only this conversation", scopes: %w[conversation])
    second = declaration("Read my persistent notes", scopes: %w[conversation agent])
    second["kernel_tools"] = ["nexus.memory.read", "nexus.memory.ls"]
    other = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    created = User.count
    one = accept(@conversation, agent_configuration: first,
      model_selection: ModelSelectionIntent.explicit("dev/mock-text").as_json, fallback_models: [])
    two = accept(other, agent_configuration: second)
    first["system_prompt"]["content"] = "Changed outside the accepted capture"
    declare_tools!(@agent, tools: [], default_model: "dev/mock-priced", fallback_models: ["dev/mock-priced"])
    PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt", content: "Current User prompt")

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: other.id)
    assert_equal created, User.count
    runs = [@conversation, other].map { |conversation| conversation.turns.last.active_variant.run }
    left, right = runs
    runs.each do |run|
      assert_equal @agent, run.answering_user
      assert_equal @agent, run.execution_agent
      assert_equal @human, run.creating_user
      assert_equal "dev/mock-text", run.model_selection.model
      assert_equal [], run.fallback_models
      assert_equal "mock-text", run.tasks.sole.model_ref
    end
    assert_equal "explicit", left.model_selection.source
    assert_equal "route", left.model_selection.constraint
    assert_equal %w[memory_read], tool_names(left)
    assert_equal %w[memory_ls memory_read], tool_names(right).sort
    assert_equal %w[conversation], MemoryContext.from_h(left.memory_context).bindings.map(&:name)
    assert_equal %w[agent conversation], MemoryContext.from_h(right.memory_context).bindings.map(&:name).sort
    assert_includes request_text(left), "Read only this conversation"
    refute_includes request_text(left), "Changed outside the accepted capture"
    assert_includes request_text(right), "Read my persistent notes"
    refute_includes request_text(right), "Current User prompt"
    assert_equal one.public_id, left.turn.input_public_id
    assert_equal two.public_id, right.turn.input_public_id

    written = Conversations::Memory::Apply.write(conversation: other, path: "agent/note.md", content: "Keep this identity",
      by: @human, expected: memory_expectation)
    assert_predicate written, :accepted?, written.outcome.inspect
    assert_equal @agent.id, written.value.memory_collection.user_id
    context = MemoryDocuments::Context.new(workspace: @workspace, conversation: other, principal: @human,
      configuration: right.memory_context, agent: right.execution_agent)
    assert_equal "Keep this identity", context.resolve("agent/note.md").documents.sole.content
  end

  test "the omitted declaration resolves once at materialization then regeneration keeps that capture" do
    declare_tools!(@agent)
    accept(@conversation)
    PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt", content: "At materialization")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    turn = @conversation.turns.last
    original = turn.active_variant
    run = original.run
    assert_equal "At materialization", original.agent_configuration.system_prompt.content
    Runs::Transition.run(run, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call
    PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt", content: "Later User change")
    declare_tools!(@agent, tools: [], fallback_models: ["dev/mock-priced"])

    result = regenerate(turn, model_ref: "mock-priced")

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal original.agent_configuration, result.value.agent_configuration
    assert_equal [], result.value.fallback_models
    assert_includes request_text(result.value.run), "At materialization"
    refute_includes request_text(result.value.run), "Later User change"
  end

  test "regeneration may replace the declaration without mutating the old execution" do
    accept(@conversation, agent_configuration: declaration("First instructions", scopes: %w[conversation]))
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    turn = @conversation.turns.last
    original = turn.active_variant
    Runs::Transition.run(original.run, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call
    replacement = declaration("Replacement instructions", scopes: %w[conversation agent])
    replacement["kernel_tools"] = []
    replacement["approval_mode"] = nil

    result = regenerate(turn, agent_configuration: replacement,
      model_selection: ModelSelectionIntent.explicit("dev/mock-text").as_json)

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_nil result.value.run
    assert_equal "explicit", result.value.model_selection.source
    assert_equal "Replacement instructions", result.value.agent_configuration.system_prompt.content
    assert_equal "First instructions", original.reload.agent_configuration.system_prompt.content
    body = result.value.model_invocation.content_bodies.find_by!(role: "request")
    assert_includes body.entry_payloads.to_json, "Replacement instructions"
    refute_includes body.entry_payloads.to_json, "First instructions"
  end

  test "editing an answer retains the declaration used by its next regeneration" do
    turn = completed_captured_turn
    original = turn.active_variant
    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation.reload, turn_public_id: turn.public_id,
      acting_user: @human, entries: [{ "text" => "Corrected answer" }]))
    assert_predicate edited, :accepted?, edited.outcome.inspect
    assert_nil edited.value.run
    assert_equal original.agent_configuration, edited.value.agent_configuration
    declare_tools!(@agent, tools: [])

    result = regenerate(turn)

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal "Captured for later", result.value.agent_configuration.system_prompt.content
    assert_equal %w[memory_read], tool_names(result.value.run)
    assert_includes request_text(result.value.run), "Captured for later"
    assert_equal "explicit", result.value.model_selection.source
    assert_equal [], result.value.fallback_models
  end

  test "a fork preserves execution configuration and compiles it under the same principal on regeneration" do
    turn = completed_captured_turn
    original = turn.active_variant
    result = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @conversation.reload, turn_public_id: turn.public_id,
      variant_public_id: original.public_id, acting_user: @human, title: "Fork"))
    assert_predicate result, :accepted?, result.outcome.inspect
    @conversation = result.value
    copied = @conversation.turns.sole
    assert_equal original.agent_configuration, copied.active_variant.agent_configuration
    declare_tools!(@agent, tools: [])

    regenerated = regenerate(copied)

    assert_predicate regenerated, :accepted?, regenerated.outcome.inspect
    assert_equal @agent, regenerated.value.run.answering_user
    assert_equal %w[memory_read], tool_names(regenerated.value.run)
    assert_includes request_text(regenerated.value.run), "Captured for later"
    assert_equal original.model_selection, regenerated.value.model_selection
    assert_equal [], regenerated.value.fallback_models
  end

  %w[edit fork].each do |copy_kind|
    [[], ["memory_read"]].each do |selected|
      test "#{copy_kind} regeneration keeps the materialized tool subset #{selected.inspect}" do
        configuration = declaration("Keep the selected tools", scopes: %w[conversation])
        configuration["kernel_tools"] = %w[nexus.memory.read nexus.memory.ls]
        accept(@conversation, agent_configuration: configuration, tool_names: selected)
        Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
        turn = @conversation.turns.last
        original = turn.active_variant
        Runs::Transition.run(original.run, status: "completed", completed_at: Time.current)
        Conversations::Turns::Converge.call
        assert_equal selected, Nexus::ToolDeclarations.names(original.agent_configuration.tool_definitions)
        assert_nil original.agent_configuration.kernel_tools
        assert_equal [], original.agent_configuration.runner_tool_names

        if copy_kind == "edit"
          copied = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
            conversation: @conversation.reload, turn_public_id: turn.public_id,
            acting_user: @human, entries: [{ "text" => "Corrected answer" }]))
        else
          copied = Conversations::Fork.call(Conversations::Fork::Command.new(
            conversation: @conversation.reload, turn_public_id: turn.public_id,
            variant_public_id: original.public_id, acting_user: @human, title: "Fork"))
        end
        assert_predicate copied, :accepted?, copied.outcome.inspect
        if copy_kind == "fork"
          @conversation = copied.value
          turn = @conversation.turns.sole
        end
        declare_tools!(@agent, tools: [READ_TOOL, Nexus::Tools::SKILL])

        regenerated = regenerate(turn)

        assert_predicate regenerated, :accepted?, regenerated.outcome.inspect
        variant = regenerated.value
        if selected.empty?
          assert_nil variant.run
          assert_empty variant.model_invocation.request_options.fetch("tools", [])
        else
          assert_equal selected, tool_names(variant.run)
        end
        assert_equal selected, Nexus::ToolDeclarations.names(variant.agent_configuration.tool_definitions)
      end
    end
  end

  private

    def completed_captured_turn
      accept(@conversation, agent_configuration: declaration("Captured for later", scopes: %w[conversation]),
        model_selection: ModelSelectionIntent.explicit("dev/mock-text").as_json)
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      turn = @conversation.turns.last
      Runs::Transition.run(turn.active_variant.run, status: "completed", completed_at: Time.current)
      Conversations::Turns::Converge.call
      turn.reload
    end

    def declaration(text, scopes:)
      { "kernel_tools" => ["nexus.memory.read"], "approval_mode" => "bypass", "prompt_mechanism" => "default",
        "default_model" => "dev/mock-text", "fallback_models" => [],
        "system_prompt" => { "content" => text, "role" => "system" },
        "memory_context_limit" => { "bindings" => scopes.map { |scope|
          { "name" => scope, "source" => { "scope" => scope }, "access" => "read_write" }
        } } }
    end

    def accept(conversation, **options)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: conversation, acting_user: @human, kind: "direct_reply", role: "user",
        entries: [{ "text" => "The question" }], visible_in_context: true, delivery_mode: "queue",
        context_mode: nil, context_options: nil, expected_context_revision: nil,
        expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: "mock-text",
        reasoning_effort: nil, request_options: nil, **options))
      assert_predicate result, :accepted?, result.outcome.inspect
      result.value
    end

    def regenerate(turn, model_ref: nil, **options)
      Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
        conversation: @conversation.reload, turn_public_id: turn.public_id, acting_user: @human,
        provider_id: model_ref ? "dev" : nil, model_ref: model_ref, reasoning_effort: nil,
        request_options: nil, **options))
    end

    def request_text(run) = run.tasks.sole.content_bodies.find_by!(role: "input").entry_payloads.to_json
    def tool_names(run) = Nexus::ToolDeclarations.names(run.tasks.sole.tool_definitions)
end
