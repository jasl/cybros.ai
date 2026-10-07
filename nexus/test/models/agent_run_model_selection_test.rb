require "test_helper"

class AgentRunModelSelectionTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@workspace.account)
    @agent_run = seed(model("answer"), default_runner_executor_public_id: nil)
    @node = @agent_run.agent_run_tasks.find_by!(node_key: "answer")
  end

  test "each model selection field requires exactly the next execution generation" do
    replacement.each do |attribute, value|
      assert_not @node.update(attribute => value), attribute.to_s
      assert @node.errors.of_kind?(:base, :model_change_requires_new_execution), attribute.to_s
      @node.reload
    end

    assert_not @node.update(**replacement, execution_generation: @node.execution_generation + 2)
    assert @node.errors.of_kind?(:base, :model_change_requires_new_execution)
    @node.reload

    generation = @node.execution_generation
    @node.update!(**replacement, execution_generation: generation + 1)
    assert_equal replacement.stringify_keys, @node.reload.attributes.slice(*replacement.keys.map(&:to_s))
    assert_equal generation + 1, @node.execution_generation
    assert_equal "queued", @node.status
  end

  test "advancing the generation cannot change a running model until it requeues" do
    AgentRuns::Transition.node(@node, status: "running", started_at: Time.current)
    generation = @node.execution_generation

    assert_not @node.update(**replacement, execution_generation: generation + 1)
    assert @node.errors.of_kind?(:base, :model_change_requires_new_execution)
    assert_equal "mock-text", @node.reload.model_ref
    assert_equal generation, @node.execution_generation

    @node.update!(**replacement, status: "queued", started_at: nil, execution_generation: generation + 1)
    assert_equal "queued", @node.reload.status
    assert_equal replacement.fetch(:model_ref), @node.model_ref
  end

  test "a new model generation leaves the previous invocation and sealed request immutable" do
    started = AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: @agent_run, acting_user: @human))
    assert_predicate started, :accepted?
    AgentRuns::ScheduleReady.call(agent_run_id: @agent_run.id)
    invocation = @node.reload.selected_model_invocation
    assert_not_nil invocation
    request = invocation.content_bodies.find_by!(role: "request")
    original_selection = invocation.attributes.slice("provider_id", "model_ref", "reasoning_effort", "reasoning_enabled")
    original_entries = request.content_body_entries.map { |entry| entry.content_fragment.payload }
    original_text = request.effective_text

    invocation.terminalize(status: "failed", reason_key: "provider_model_unavailable")
    AgentRuns::Transition.node(@node, status: "failed", completed_at: Time.current,
      error_key: "provider_model_unavailable")
    @node.update!(**replacement, status: "queued", execution_generation: @node.execution_generation + 1,
      started_at: nil, completed_at: nil, error_key: nil)

    assert_equal original_selection, invocation.reload.attributes.slice(*original_selection.keys)
    assert_equal original_entries, request.reload.content_body_entries.map { |entry| entry.content_fragment.payload }
    assert_equal original_text, request.effective_text
    assert_predicate request, :sealed?
    replacement.each do |attribute, value|
      assert_raises(ActiveRecord::ReadonlyAttributeError) { invocation.update!(attribute => value) }
      invocation.reload
    end
    assert_not request.update(readable_text: "replacement request")
    assert request.errors.of_kind?(:readable_text, :readonly)
    assert_equal original_text, request.reload.effective_text
  end

  test "the model selection exception does not relax other task kinds or frozen definitions" do
    graph = seed(parallel(tool("read", "read_file"), ask("question"), until: "any", losers: "run_out"), model("finish"))
    %w[tool_task await_task join_task].each do |kind|
      node = graph.agent_run_tasks.find { |candidate| candidate.class.task_kind == kind }
      assert_not_nil node, kind
      replacement.each do |attribute, value|
        assert_raises(ActiveRecord::ReadonlyAttributeError) do
          node.update!(attribute => value, execution_generation: node.execution_generation + 1)
        end
        assert_nil node.reload.public_send(attribute)
      end
    end

    {
      request_options: { "temperature" => 0.25 }, tool_definitions: [],
      system_instructions: "different instructions", input_from_node_keys: ["another"],
      compaction: { "mode" => "off" }, on_failure: "absorb", retry_budget: 2,
    }.each do |attribute, value|
      original = @node.public_send(attribute)
      assert_raises(ActiveRecord::ReadonlyAttributeError) do
        @node.update!(attribute => value, execution_generation: @node.execution_generation + 1)
      end
      original.nil? ? assert_nil(@node.reload.public_send(attribute)) : assert_equal(original, @node.reload.public_send(attribute))
    end
  end

  private

    def replacement
      { provider_id: "alternate", model_ref: "replacement", reasoning_effort: "high", reasoning_enabled: false }
    end
end
