require "test_helper"
require "test_helpers/agent_runs_result_delivery_test_helper"

class AgentRuns::ResultDeliveryEnvironmentsTest < ActiveJob::TestCase
  include AgentRunsResultDeliveryTestHelper

  setup do
    @runner_a = runner("alpha", "Alpha workspace")
    @runner_b = runner("beta", "Beta workspace")
    @agent.update!(runner_executor_public_ids: [@runner_a.public_id, @runner_b.public_id])
    select_runner(@runner_a)
  end

  test "a background receipt retains its source Runner after the host selects another environment" do
    guidance = "Report the checks before suggesting changes."
    _turn, source = materialize_loop_reply!(@conversation, agent: @agent,
      text: "run the suite while I keep working",
      context_options: { "inline" => [{ "role" => "developer", "position" => "lead", "text" => guidance }] })
    schedule_loop!(source)
    call_round!(source, "r1", "delegate_task", { prompt: "long test run" })
    run_round!(source, "r2", "meanwhile, here is what I know")
    converge!
    last_request = round_request_entries(loop_node(source, "r2"))
    original_seed = loop_node(source, "r1")
    original_environment = original_seed.operation_context.fetch("environment")
    select_runner(@runner_b)
    announced = @runner_a.announce(tools: @runner_a.served_tools,
      environment: { "fragments" => [{ "text" => "Changed Alpha workspace" }] })
    assert_predicate announced, :accepted?
    run_round!(source, "r2t0-model-1", "Alpha checks passed")

    assert_equal [:delivered], AgentRuns::ResultDelivery.call(source.reload)
    mail = @conversation.conversation_inputs.sole
    assert_equal "direct_reply", mail.kind
    assert_equal source.public_id, mail.sender_run_public_id
    assert_includes mail.tool_names, "bash"

    applied = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
    assert_predicate applied, :accepted?, applied.outcome.to_s
    reply = applied.value.active_variant.agent_run
    seed = loop_node(reply, "r1")
    assert_equal original_seed.tool_definitions, seed.tool_definitions
    assert_equal original_environment, seed.operation_context.fetch("environment")
    bash = seed.tool_definitions.find { |entry| Nexus::ToolDeclarations.name_of(entry) == "bash" }
    assert_equal @runner_a.public_id, bash.dig("route", "runner_executor_public_id")
    assert_equal @runner_b.public_id, @conversation.reload.default_runner.public_id

    schedule_loop!(reply)
    entries = round_request_entries(seed.reload)
    assert_equal last_request, entries.first(last_request.length),
      "the receipt extends the source's last request without changing its environment or product lead"
    environment_text = "Work environment: Runner #{@runner_a.public_id}.\n\nAlpha workspace"
    assert_equal 1, environment_indexes(entries, environment_text).length
    assert_equal environment_indexes(last_request, environment_text), environment_indexes(entries, environment_text)
    preface = reply.conversation_turn_variant.content_bodies.find_by!(role: "preface").entry_payloads
    assert_equal [{ "role" => "user", "parts" => [{ "type" => "text", "text" => environment_text }],
      "block" => "lead", "carried" => true }], preface,
      "the callback records the frozen environment its history already carries"
    request = entries.to_json
    assert_includes request, guidance
    assert_includes request, "Alpha workspace"
    assert_includes request, "Alpha checks passed"
    assert_not_includes request, "Beta workspace"
    assert_not_includes request, "Changed Alpha workspace"
    assert_empty @conversation.conversation_inputs

    run_round!(reply, "r1", "Alpha result acknowledged")
    converge!
    _next_turn, next_run = materialize_loop_reply!(@conversation, agent: @agent, text: "start work in Beta")
    schedule_loop!(next_run)
    next_seed = loop_node(next_run, "r1")
    assert_equal @runner_b.public_id, next_seed.operation_context.dig("environment", "default_runner_executor_public_id")
    assert_equal "Work environment: Runner #{@runner_b.public_id}.\n\nBeta workspace",
      round_request_entries(next_seed).last.dig("parts", 0, "text"),
      "a later ordinary turn appends the host's current environment"
  end

  test "withdrawing a source Runner admits its receipt once and degrades it to a message" do
    _turn, source = delivered_turn!
    converge!
    select_runner(@runner_b)
    @agent.update!(runner_executor_public_ids: [@runner_b.public_id])
    run_round!(source, "r2t0-model-1", "Alpha checks passed")

    assert_equal [:delivered], AgentRuns::ResultDelivery.call(source.reload)
    mail = @conversation.conversation_inputs.sole
    assert_equal "direct_reply", mail.kind
    assert_empty mail.tool_names
    receipt_text = mail.text
    assert_not_nil loop_node(source, "r2t0-model-1").result_delivered_at
    assert_empty AgentRuns::ResultDelivery.call(source.reload)
    assert_equal 1, @conversation.conversation_inputs.count

    applied = nil
    assert_no_difference "AgentRun.count" do
      applied = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
    end
    assert_predicate applied, :accepted?, applied.outcome.to_s
    turn = applied.value
    assert_equal %w[message completed task_result], [turn.kind, turn.status, turn.origin]
    assert_equal mail.public_id, turn.input_public_id
    assert_equal source.public_id, turn.sender_run_public_id
    assert_equal receipt_text, turn.active_variant.content_bodies.find_by!(role: "content").effective_text
    assert_nil turn.active_variant.agent_run
    assert_nil @conversation.reload.active_turn_id
    assert_empty @conversation.conversation_inputs
    assert_empty AgentRuns::ResultDelivery.call(source.reload)
  end

  private

    def environment_indexes(entries, text)
      entries.each_index.select do |index|
        entry = entries[index]
        entry["role"] == "user" && entry.fetch("parts").any? { |part| part["text"] == text }
      end
    end

    def runner(name, text)
      executor = connect_runner(manager: users(:owner), registration_identifier: "callback-env-#{name}")
        .executor_access_token.task_executor
      announced = executor.announce(tools: [{ "name" => "bash", "description" => "Run a command in #{name}",
        "input_schema" => { "type" => "object", "properties" => { "command" => { "type" => "string" } },
          "required" => ["command"] }, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }],
        environment: { "fragments" => [{ "text" => text }] })
      assert_predicate announced, :accepted?
      executor
    end

    def select_runner(executor)
      selected = Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
        host: @conversation, executor_public_id: executor.public_id, acting_user: @human
      ))
      assert_predicate selected, :accepted?, selected.outcome.to_s
    end
end
