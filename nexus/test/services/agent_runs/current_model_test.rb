require "test_helper"

class AgentRuns::CurrentModelTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  REASONING_OFF_MODEL = {
    "model" => "dev/mock-unmetered", "reasoning_enabled" => false, "reasoning_effort" => "high",
  }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @turn, @agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: "Keep the delivered result.")
    @variant = @turn.active_variant
  end

  test "a new generation reads its current choice before minting, excluding a newer branch" do
    previous = retry_on_current_model
    branch = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: @agent_run,
      steps: [AgentRuns::Tasks::Step::Model.new(key: "aside", model: { "model" => "dev/mock-windowless" },
        prompt: "A separately selected branch.")],
      tip: AgentRuns::Tasks::Tip.seed(AgentRuns::Tasks::Compile::BRANCH), origin: "kernel"
    ))
    assert_predicate branch, :applied?, branch.outcome.inspect

    assert_equal "mock-text", previous.reload.model_ref
    assert_equal "mock-text", @variant.reload.model_ref, "the seed's original selection stays frozen"
    assert_equal "mock-unmetered", AgentRuns::CurrentModel.for(@agent_run).model_ref
    assert_equal "mock-unmetered", AgentRuns::CurrentModel.for(@agent_run,
      nodes: @agent_run.agent_run_tasks.to_a).model_ref
    assert_equal "mock-unmetered", AgentRuns::CurrentModel.for_loops([@agent_run]).fetch(@agent_run.id).model_ref
    assert_equal "mock-unmetered", AgentRuns::CurrentModel.for_variant(@variant).model_ref
  end

  test "loop and timeline projections expose the retried main-line model" do
    retry_on_current_model

    %i[full basic].each do |shape|
      projected = AgentAPI::AgentRunPresenter.public_send(shape, @agent_run.reload)
      assert_equal "dev/mock-unmetered", projected.fetch(:turn).fetch(:model).fetch(:model)
    end
    projected = Conversations::TurnProjection.turn_snapshot(@turn.reload)
    assert_equal "mock-unmetered", projected.fetch(:active_variant).fetch(:model).fetch(:model_ref)
    inherited = Conversations::AnswerEngine.selection(@conversation.reload, addressee: @agent)
    assert_equal "mock-unmetered", inherited.model_ref, "the next addressed reply inherits the recovered model"
  end

  test "a fork adopts the recovered model instead of the initial model" do
    settle_retried_turn
    forked = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @conversation.reload, turn_public_id: @turn.public_id,
      variant_public_id: @variant.public_id, acting_user: @human, title: nil
    ))

    assert_predicate forked, :accepted?, forked.outcome.inspect
    adopted = forked.value.conversation_turns.order(:position).last.active_variant
    assert_equal "mock-unmetered", adopted.model_ref
    assert_nil adopted.agent_run, "the adopted choice survives without borrowing the source loop"
    assert_equal "mock-text", @variant.reload.model_ref
  end

  test "an edit carries the recovered model while the old candidate keeps its own projection" do
    settle_retried_turn
    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation.reload, turn_public_id: @turn.public_id,
      entries: [{ "text" => "Edited answer." }], acting_user: @human
    ))

    assert_predicate edited, :accepted?, edited.outcome.inspect
    assert_equal "mock-unmetered", edited.value.model_ref
    assert_equal "mock-unmetered", AgentRuns::CurrentModel.for_variant(edited.value).model_ref
    old = Conversations::TurnProjection.variant(@variant.reload, body: nil, active: false,
      loop: Conversations::TurnProjection.loop_block(@variant))
    assert_equal "mock-unmetered", old.fetch(:model).fetch(:model_ref)
    assert_equal "mock-text", @variant.model_ref
  end

  test "bare regenerate inherits the current model but judges cloning against the initial seed" do
    settle_retried_turn
    original_input = @agent_run.agent_run_tasks.find_by!(node_key: "r1").input_body
    written = PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt",
      content: "Instructions written after the original seed.", role: nil)
    assert_predicate written, :written?

    regenerated = regenerate

    assert_predicate regenerated, :accepted?, regenerated.outcome.inspect
    assert_equal "mock-unmetered", regenerated.value.model_ref
    new_seed = regenerated.value.agent_run.agent_run_tasks.find_by!(node_key: "r1")
    assert_includes new_seed.input_body.effective_text, "Instructions written after the original seed."
    assert_not_includes original_input.effective_text, "Instructions written after the original seed."
    assert_equal "mock-text", @variant.reload.model_ref
  end

  test "each variant is projected from its own loop when a later candidate uses another model" do
    settle_retried_turn
    regenerated = regenerate(model_ref: "mock-windowless")
    assert_predicate regenerated, :accepted?, regenerated.outcome.inspect
    sibling = regenerated.value
    loops = Conversations::TurnProjection.loop_blocks([@variant.id, sibling.id])

    old = Conversations::TurnProjection.variant(@variant.reload, body: nil, active: true,
      loop: loops.fetch(@variant.id))
    fresh = Conversations::TurnProjection.variant(sibling, body: nil, active: false,
      loop: loops.fetch(sibling.id))
    assert_equal "mock-unmetered", old.fetch(:model).fetch(:model_ref)
    assert_equal "mock-windowless", fresh.fetch(:model).fetch(:model_ref)
  end

  test "regenerating a retried seed back to its initial model reassembles its input" do
    settle_retried_turn
    written = PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt",
      content: "Instructions written after the retried seed.", role: nil)
    assert_predicate written, :written?

    regenerated = regenerate(model_ref: "mock-text")

    assert_predicate regenerated, :accepted?, regenerated.outcome.inspect
    assert_equal "mock-text", regenerated.value.model_ref
    new_seed = regenerated.value.agent_run.agent_run_tasks.find_by!(node_key: "r1")
    assert_includes new_seed.input_body.effective_text, "Instructions written after the retried seed."
  end

  test "manual compaction inherits the recovered model" do
    settle_retried_turn
    compacted = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: @conversation.reload, acting_user: @human
    ))

    assert_predicate compacted, :accepted?, compacted.outcome.inspect
    assert_equal "mock-unmetered", compacted.value.turn.active_variant.model_ref
  end

  test "disabled reasoning survives retry scheduling and regeneration" do
    with_reasoning_models do
      retry_on_current_model(model: REASONING_OFF_MODEL)
      current = loop_node(@agent_run, "r1")
      assert_equal [false, "high"], current.values_at(:reasoning_enabled, :reasoning_effort)

      schedule_loop!(@agent_run)
      assert_equal [false, "high"],
        current.reload.selected_model_invocation.values_at(:reasoning_enabled, :reasoning_effort)
      run_loop_round!(@agent_run, sse_success("The delivered result has been handled."))
      Conversations::Turns::Converge.call
      assert_equal "completed", @turn.reload.status

      regenerated = regenerate
      assert_predicate regenerated, :accepted?, regenerated.outcome.inspect
      assert_equal [false, "high"], regenerated.value.values_at(:reasoning_enabled, :reasoning_effort)
      new_loop = regenerated.value.agent_run
      assert_equal [false, "high"], loop_node(new_loop, "r1").values_at(:reasoning_enabled, :reasoning_effort)
      schedule_loop!(new_loop)
      assert_equal [false, "high"],
        loop_node(new_loop, "r1").selected_model_invocation.values_at(:reasoning_enabled, :reasoning_effort)
    end
  end

  test "same model retry nulls preserve disabled high reasoning and another model uses its own defaults" do
    with_reasoning_models do
      retry_on_current_model(model: REASONING_OFF_MODEL)
      fail_current_round
      preserved = retry_failed_round(model: {
        "model" => "dev/mock-unmetered", "reasoning_enabled" => nil, "reasoning_effort" => nil,
      })
      assert_equal [false, "high"], preserved.values_at(:reasoning_enabled, :reasoning_effort)

      prior = fail_current_round
      assert_equal [false, "high"], prior.values_at(:reasoning_enabled, :reasoning_effort)
      switched = retry_failed_round(model: {
        "model" => "dev/mock-windowless", "reasoning_enabled" => nil, "reasoning_effort" => nil,
      })
      assert_equal ["mock-windowless", true, "low"],
        switched.values_at(:model_ref, :reasoning_enabled, :reasoning_effort),
        "this target can disable reasoning, so retaining false would change its default"
      schedule_loop!(@agent_run)
      assert_equal [true, "low"],
        switched.reload.selected_model_invocation.values_at(:reasoning_enabled, :reasoning_effort)
    end
  end

  test "manual compaction preserves the recovered disabled reasoning selection" do
    with_reasoning_models do
      settle_retried_turn(model: REASONING_OFF_MODEL)
      compacted = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
        conversation: @conversation.reload, acting_user: @human
      ))

      assert_predicate compacted, :accepted?, compacted.outcome.inspect
      summary = compacted.value.turn.active_variant
      assert_equal ["mock-unmetered", false, "high"],
        summary.values_at(:model_ref, :reasoning_enabled, :reasoning_effort)
      schedule_loop!(summary.agent_run)
      assert_equal [false, "high"],
        summary.agent_run.model_invocations.sole.values_at(:reasoning_enabled, :reasoning_effort)
    end
  end

  test "fallback projections report the current invocation's effective disabled default" do
    with_reasoning_models(default_enabled: false) do
      declare_tools!(@agent, fallback_model: "dev/mock-unmetered")
      schedule_loop!(@agent_run)
      run_loop_round!(@agent_run, sse_refused("The provider declined the original request."))

      current = loop_node(@agent_run, "r1")
      assert_equal "mock-unmetered", current.model_ref
      assert_nil current.reasoning_enabled, "the fallback task requests the target model's defaults"
      assert_nil current.reasoning_effort
      assert_equal [false, "low"],
        current.selected_model_invocation.values_at(:reasoning_enabled, :reasoning_effort)

      [AgentRuns::CurrentModel.for(@agent_run),
       AgentRuns::CurrentModel.for(@agent_run, nodes: @agent_run.agent_run_tasks.to_a),
       AgentRuns::CurrentModel.for_loops([@agent_run]).fetch(@agent_run.id)].each do |selection|
        assert_equal [false, "low"], selection.values_at(:reasoning_enabled, :reasoning_effort)
      end
      projections = %i[full basic].map { |shape| AgentAPI::AgentRunPresenter.public_send(shape, @agent_run.reload) }
      projections << AgentAPI::AgentRunPresenter.basic_many([@agent_run]).sole
      projections.each do |projection|
        assert_equal({ model: "dev/mock-unmetered", reasoning_enabled: false, reasoning_effort: "low" },
          projection.fetch(:turn).fetch(:model))
      end
      snapshot = Conversations::TurnProjection.turn_snapshot(@turn.reload)
      assert_equal({ provider_id: "dev", model_ref: "mock-unmetered", reasoning_enabled: false, reasoning_effort: "low" },
        snapshot.fetch(:active_variant).fetch(:model))
    end
  end

  private

    def with_reasoning_models(default_enabled: true, &block)
      catalog = ModelCatalog.current
      models = catalog.models.deep_dup
      %w[dev/mock-unmetered dev/mock-windowless].each do |model|
        models.fetch(model).fetch("capabilities")["reasoning"] = {
          "efforts" => %w[low high], "default_effort" => "low",
          "default_enabled" => default_enabled, "disable_supported" => true,
        }
      end
      ModelCatalog.stub(:current, catalog.with(models: models), &block)
    end

    def retry_on_current_model(model: { "model" => "dev/mock-unmetered" })
      previous = fail_current_round
      retry_failed_round(model: model)
      previous
    end

    def fail_current_round
      schedule_loop!(@agent_run)
      attempt = loop_attempt(@agent_run)
      apply_via(attempt, json_response(401, { "error" => { "message" => "Model access expired." } }))
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(@agent_run)
      Conversations::Turns::Converge.call
      assert_equal "needs_attention", @agent_run.reload.status
      attempt.model_invocation
    end

    def retry_failed_round(model:)
      retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
        agent_run: @agent_run, task_key: "r1", acting_user: @human,
        model: model
      ))
      assert_predicate retried, :accepted?, retried.outcome.inspect
      retried.node
    end

    def settle_retried_turn(model: { "model" => "dev/mock-unmetered" })
      retry_on_current_model(model: model)
      schedule_loop!(@agent_run)
      run_loop_round!(@agent_run, sse_success("The delivered result has been handled."))
      Conversations::Turns::Converge.call
      assert_equal "completed", @turn.reload.status
    end

    def regenerate(model_ref: nil)
      Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
        conversation: @conversation.reload, turn_public_id: @turn.public_id,
        acting_user: @human, provider_id: nil, model_ref: model_ref,
        reasoning_effort: nil, request_options: nil
      ))
    end
end
