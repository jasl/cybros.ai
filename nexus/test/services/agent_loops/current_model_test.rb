require "test_helper"

class AgentLoops::CurrentModelTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @turn, @agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "Keep the delivered result.")
    @variant = @turn.active_variant
  end

  test "a new generation reads its current choice before minting, excluding a newer branch" do
    previous = retry_on_current_model
    branch = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
      agent_loop: @agent_loop,
      steps: [AgentLoops::Tasks::Step::Model.new(key: "aside", model: { "model" => "dev/mock-windowless" },
        prompt: "A separately selected branch.")],
      tip: AgentLoops::Tasks::Tip.seed(AgentLoops::Tasks::Compile::BRANCH), origin: "kernel"
    ))
    assert_predicate branch, :applied?, branch.outcome.inspect

    assert_equal "mock-text", previous.reload.model_ref
    assert_equal "mock-text", @variant.reload.model_ref, "the seed's original selection stays frozen"
    assert_equal "mock-unmetered", AgentLoops::CurrentModel.for(@agent_loop).model_ref
    assert_equal "mock-unmetered", AgentLoops::CurrentModel.for(@agent_loop,
      nodes: @agent_loop.agent_loop_nodes.to_a).model_ref
    assert_equal "mock-unmetered", AgentLoops::CurrentModel.for_loops([@agent_loop]).fetch(@agent_loop.id).model_ref
    assert_equal "mock-unmetered", AgentLoops::CurrentModel.for_variant(@variant).model_ref
  end

  test "loop and timeline projections expose the retried main-line model" do
    retry_on_current_model

    %i[full basic].each do |shape|
      projected = AgentAPI::AgentLoopPresenter.public_send(shape, @agent_loop.reload)
      assert_equal "dev/mock-unmetered", projected.fetch(:turn).fetch(:model).fetch(:model)
    end
    projected = Conversations::TurnProjection.turn_snapshot(@turn.reload)
    assert_equal "mock-unmetered", projected.fetch(:active_variant).fetch(:model).fetch(:model_ref)
    inherited = Conversations::AnswerEngine.trio(@conversation.reload, addressee: @agent)
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
    assert_nil adopted.agent_loop, "the adopted choice survives without borrowing the source loop"
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
    assert_equal "mock-unmetered", AgentLoops::CurrentModel.for_variant(edited.value).model_ref
    old = Conversations::TurnProjection.variant(@variant.reload, body: nil, active: false,
      loop: Conversations::TurnProjection.loop_block(@variant))
    assert_equal "mock-unmetered", old.fetch(:model).fetch(:model_ref)
    assert_equal "mock-text", @variant.model_ref
  end

  test "bare regenerate inherits the current model but judges cloning against the initial seed" do
    settle_retried_turn
    original_input = @agent_loop.agent_loop_nodes.find_by!(node_key: "r1").input_body
    written = PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt",
      content: "Instructions written after the original seed.", role: nil)
    assert_predicate written, :written?

    regenerated = regenerate

    assert_predicate regenerated, :accepted?, regenerated.outcome.inspect
    assert_equal "mock-unmetered", regenerated.value.model_ref
    new_seed = regenerated.value.agent_loop.agent_loop_nodes.find_by!(node_key: "r1")
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
    new_seed = regenerated.value.agent_loop.agent_loop_nodes.find_by!(node_key: "r1")
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

  private

    def retry_on_current_model
      schedule_loop!(@agent_loop)
      attempt = loop_attempt(@agent_loop)
      apply_via(attempt, json_response(401, { "error" => { "message" => "Model access expired." } }))
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(@agent_loop)
      Conversations::Turns::Converge.call
      assert_equal "needs_attention", @agent_loop.reload.status

      retried = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
        agent_loop: @agent_loop, task_key: "r1", acting_user: @human,
        model: { "model" => "dev/mock-unmetered" }
      ))
      assert_predicate retried, :accepted?, retried.outcome.inspect
      attempt.model_invocation
    end

    def settle_retried_turn
      retry_on_current_model
      schedule_loop!(@agent_loop)
      run_loop_round!(@agent_loop, sse_success("The delivered result has been handled."))
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
