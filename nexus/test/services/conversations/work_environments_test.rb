require "test_helper"
require_relative "../../test_helpers/inputs_apply_next_test_helper"

class Conversations::WorkEnvironmentsTest < ActiveSupport::TestCase
  include InputsApplyNextTestHelper

  setup do
    @local = runner("local", "Local workspace")
    @remote = runner("remote", "Remote build workspace")
    @agent.update!(approval_mode: "bypass", kernel_tools: %w[nexus.conversation.spawn nexus.runners.list],
      runner_executor_public_ids: [@local.public_id, @remote.public_id])
    answered_by!(@agent)
    @conversation.update!(default_runner_executor: @remote)
  end

  test "a reply compiles exact selected tools before name narrowing and freezes its environment" do
    reply!(tool_names: ["bash"])
    assert_equal 1, drain!
    seed = seed_of(reply_variant.agent_run)
    assert_equal ["bash"], Nexus::ToolDeclarations.names(seed.tool_definitions)
    assert_equal @remote.public_id, seed.tool_definitions.sole.dig("route", "runner_executor_public_id")
    assert_equal @remote.serving("bash").fetch("input_schema"), seed.tool_definitions.sole.dig("function", "parameters")
    environment = seed.operation_context.fetch("environment")
    assert_equal @remote.public_id, environment.fetch("default_runner_executor_public_id")
    assert_equal [@local.public_id, @remote.public_id], environment.fetch("runner_candidates")
      .map { |entry| entry.fetch("runner_executor_public_id") }
    text = seed.input_body.effective_text
    assert_includes text, "Remote build workspace"
    assert_not_includes text, "Local workspace"

    @conversation.reload.update!(default_runner_executor: @local)
    @remote.announce(tools: [], environment: { "fragments" => [{ "text" => "Changed environment" }] })
    @agent.update!(runner_executor_public_ids: [@local.public_id])
    assert_equal environment, seed.reload.operation_context.fetch("environment")
    assert_equal @remote.public_id, seed.tool_definitions.sole.dig("route", "runner_executor_public_id")
    assert_equal text, seed.input_body.effective_text
  end

  test "raw requests retain authored bytes while their selected tool surface still freezes" do
    @agent.update!(prompt_mechanism: "raw")
    reply!(text: "Only the authored words", tool_names: ["bash"])
    assert_equal 1, drain!
    seed = seed_of(reply_variant.agent_run)
    assert_equal "Only the authored words", seed.input_body.effective_text
    assert_equal @remote.public_id, seed.operation_context.dig("environment", "default_runner_executor_public_id")
  end

  test "an assembly template without a lead keeps the environment out of its authored layout" do
    @agent.update!(prompt_mechanism: "assembly", prompt_template: { "blocks" => [
      { "type" => "history" }, { "type" => "input" },
    ] })
    reply!(text: "Only the requested input", tool_names: ["bash"])
    assert_equal 1, drain!
    seed = seed_of(reply_variant.agent_run)
    assert_equal [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "Only the requested input" }] }],
      seed.input_body.entry_payloads
    assert_equal @remote.public_id, seed.operation_context.dig("environment", "default_runner_executor_public_id")
    assert_nil reply_variant.content_bodies.find_by(role: "preface")
  end

  test "a queued narrowed reply parks durably when its selected Runner is no longer declared" do
    input = reply!(tool_names: ["bash"])
    @agent.update!(runner_executor_public_ids: [@local.public_id])
    result = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
    assert_equal :input_blocked, result.outcome
    assert_equal ["blocked", "runner_not_declared"], input.reload.attributes.values_at("state", "blocked_reason")
    assert_empty @conversation.conversation_turns
  end

  test "an explicit absence keeps candidate discovery and imports no Runner tools" do
    @conversation.update!(default_runner_executor: nil)
    reply!
    assert_equal 1, drain!
    seed = seed_of(reply_variant.agent_run)
    assert_equal %w[runners_list spawn], Nexus::ToolDeclarations.names(seed.tool_definitions)
    assert_nil seed.operation_context.dig("environment", "default_runner_executor_public_id")
    assert_equal 2, seed.operation_context.dig("environment", "runner_candidates").length
    assert_includes seed.input_body.effective_text, "no Runner selected"
  end

  test "regeneration keeps the original environment after the host selects another Runner" do
    skill = { "name" => "skill", "description" => "Read environment guidance",
      "input_schema" => { "type" => "object", "properties" => { "name" => { "type" => "string" } } },
      "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }
    @remote.announce(tools: [*@remote.served_tools, skill], environment: @remote.environment,
      documents: [{ "name" => "original-guide", "description" => "Guidance accepted with this task" }])
    reply!
    drain!
    origin = reply_variant.agent_run
    turn = origin.conversation_turn
    seed = seed_of(origin)
    AgentRuns::Transition.agent_run(origin, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call
    @conversation.reload.update!(default_runner_executor: @local)
    @remote.announce(tools: @remote.served_tools, environment: @remote.environment,
      documents: [{ "name" => "later-guide", "description" => "Guidance published after acceptance" }])
    result = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id, acting_user: @user,
      provider_id: "dev", model_ref: "mock-priced", reasoning_effort: nil, request_options: nil
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    regenerated = seed_of(result.value.agent_run)
    assert_equal seed.tool_definitions, regenerated.tool_definitions
    assert_equal seed.operation_context, regenerated.operation_context
    assert_includes regenerated.input_body.effective_text, "Remote build workspace"
    assert_not_includes regenerated.input_body.effective_text, "Local workspace"
    assert_includes regenerated.input_body.effective_text, "original-guide"
    assert_not_includes regenerated.input_body.effective_text, "later-guide"
  end

  private

    def seed_of(agent_run) = agent_run.agent_run_tasks.find_by!(node_key: "r1")

    def runner(name, text)
      executor = connect_runner(manager: users(:owner), registration_identifier: "work-env-#{name}",
        assignment_scope: :account_wide).executor_access_token.task_executor
      executor.announce(tools: [{ "name" => "bash", "description" => "Run a command in #{name}",
        "input_schema" => { "type" => "object", "properties" => { "command" => { "type" => "string" } },
          "required" => ["command"] }, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }],
        environment: { "fragments" => [{ "text" => text }] })
      executor
    end
end
