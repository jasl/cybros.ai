require "test_helper"
require_relative "../../test_helpers/lock_order_test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class AgentLoops::DelegationsTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper
  include AgentMembershipTestHelper
  include LockOrderTestHelper
  include RowLockTestHelper

  uses_transaction :test_duplicate_child_hint_and_source_recovery_publish_one_waited_completion
  uses_transaction :test_publication_overlapping_source_reap_commits_no_unowned_input

  PROMPT = "Report a concise result.".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::SPAWN, READ_TOOL])
  end

  def say!(text) = post_input!(@conversation, acting_user: @human, text: text)

  def open_turn!(text = "go")
    say!(text)
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(agent_loop)
    [turn, agent_loop]
  end

  def attempt_for(agent_loop, key)
    invocation_id = loop_node(agent_loop, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  # The running round answers with `spawn` calls; the kernel's jobs run.
  def spawn_round!(agent_loop, *calls, key: "r1")
    prepare_spawn_round!(agent_loop, *calls, key: key)
    perform_enqueued_jobs(only: [AgentLoops::ConversationToolJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    agent_loop.reload
  end

  def prepare_spawn_round!(agent_loop, *calls, key: "r1")
    tool_calls = calls.each_with_index.map do |fields, index|
      { id: "call_#{index}", name: "spawn", arguments: fields.to_json }
    end
    apply_via(attempt_for(agent_loop, key), sse_success("delegating", tool_calls: tool_calls))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
  end

  def prepare_launch
    _turn, parent = open_turn!
    prepare_spawn_round!(parent, { prompt: PROMPT, lifetime: "turn" })
    schedule_loop!(parent)
    [parent, call_node(parent)]
  end

  def run_round!(agent_loop, key, text)
    apply_via(attempt_for(agent_loop, key), sse_success(text))
    AgentLoops::ConvergeTerminalSteps.call
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    agent_loop.reload
  end

  def spawning_loop(*calls)
    _turn, agent_loop = open_turn!
    spawn_round!(agent_loop, *calls)
    refute call_node(agent_loop).output_summary["is_error"], tool_result(agent_loop, "r2t0")
    agent_loop
  end

  def call_node(agent_loop, key = "r2t0") = loop_node(agent_loop, key)
  def child_of(agent_loop, key = "r2t0") = Conversation.find_by(spawn_node_id: call_node(agent_loop, key).id)
  def tool_result(agent_loop, key) = loop_node(agent_loop, key).content_bodies.find_by(role: "output")&.effective_text

  def sources_of(agent_loop, key)
    loop_node(agent_loop, key).incoming_edges.includes(:from_node).map { |edge| edge.from_node.node_key }.sort
  end

  def paired_results(agent_loop, key)
    round_request_entries(loop_node(agent_loop, key)).select { |payload| payload["type"] == "tool_result_item" }
      .to_h { |payload| [payload.dig("payload", "call_id"), payload.dig("payload", "output")] }
  end

  def request_texts(agent_loop, key)
    round_request_entries(loop_node(agent_loop, key)).filter_map { |payload| payload.dig("parts", 0, "text") }
  end

  def spawn_envelope(call, status, child, text)
    "<task_result task=\"#{call}\" status=\"#{status}\" conversation=\"#{child.public_id}\">\n#{text}\n</task_result>"
  end

  def delegation(agent_loop) = call_node(agent_loop).spawn_delegation

  def start_child(agent_loop)
    child = child_of(agent_loop)
    result = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert result.accepted?, result.outcome.inspect
    child_loop = result.value.active_variant.agent_loop
    schedule_loop!(child_loop) if child_loop
    [child, result.value, child_loop]
  end

  def relay(child)
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
  end

  # Every budgeted attempt of a direct reply answers the provider's overload.
  def overload_reply!(invocation)
    3.times do
      ModelInvocation.where(id: invocation.id).update_all(next_admission_at: 1.second.ago)
      ModelInvocations::AdmitQueuedWork.call
      apply_via(invocation.attempts.order(:id).last,
        json_response(529, { "error" => { "type" => "overloaded_error", "message" => "Overloaded" } }))
    end
    assert_equal "provider_overloaded", invocation.reload.failure_reason_key
  end

  test "an asynchronous delegated result is synthesized before final delivery" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn" })
    child, turn, child_loop = start_child(parent)
    assert_equal "turn", loop_node(child_loop, "r1").lifetime
    run_round!(parent, "r2", "candidate answer")
    refute parent.delivered?
    assert_equal "running", delegation(parent).status

    run_round!(child_loop, "r1", "original child report")
    assert_ladder_order("delegated completion and synthesis") { relay(child) }
    assert_ladder_order("duplicate delegation relay") { relay(child) }
    assert_equal "completed", delegation(parent).reload.status
    assert turn.reload.relayed_at
    assert_equal 0, @conversation.conversation_inputs.where(origin: "child").count
    schedule_loop!(parent)
    assert_equal 1, request_texts(parent, "w1").join.scan("original child report").length
    run_round!(parent, "w1", "synthesized final")
    assert parent.delivered?
  end

  test "a waited result replaces the wait read and reaches the model exactly once" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn", wait: true })
    child, _turn, child_loop = start_child(parent)
    assert_equal "dispatched", call_node(parent).spawn_await.status
    run_round!(child_loop, "r1", "waited report")
    assert_ladder_order("wait settlement and read replacement") { relay(child) }
    schedule_loop!(parent)

    assert_equal "completed", delegation(parent).status
    assert_equal "completed", call_node(parent).spawn_await.status
    reads = loop_node(parent, "r2").input_from_node_keys
    assert_includes reads, delegation(parent).node_key
    refute_includes reads, call_node(parent).spawn_await.node_key
    assert_includes sources_of(parent, "r2"), call_node(parent).spawn_await.node_key
    assert_equal 1, paired_results(parent, "r2").values.join.scan("waited report").length
    refute_includes request_texts(parent, "r2").join, "waited report"
    assert_equal delegation(parent).id, AgentLoops::BranchClosure.tip_of(call_node(parent)).id
    run_round!(parent, "r2", "finished")
    assert parent.delivered?
  end

  test "an expired short wait does not release delegated completion" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn", wait: true })
    child, _turn, child_loop = start_child(parent)
    await = call_node(parent).spawn_await
    await.update_columns(await_started_at: 2.hours.ago)
    AgentLoops::Parks::Settle.call(node: await, timeout: true)
    schedule_loop!(parent)
    run_round!(parent, "r2", "still collecting")
    refute parent.delivered?
    assert_equal "running", delegation(parent).status

    run_round!(child_loop, "r1", "late report")
    relay(child)
    schedule_loop!(parent)
    assert_equal "timed_out", await.reload.status
    assert_equal 1, request_texts(parent, "w1").join.scan("late report").length
    assert_equal await.id, AgentLoops::BranchClosure.tip_of(call_node(parent)).id
  end

  test "deleting an unpublished execution input leaves an abandoned result and releases the wait" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn", wait: true })
    child = child_of(parent)
    input = child.conversation_inputs.sole
    result = nil
    assert_ladder_order("delegated input removal") do
      result = Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
        host: child, input_public_id: input.public_id, acting_user: @agent))
    end
    assert result.accepted?
    assert_equal "failed", delegation(parent).reload.status
    assert_equal "delegation_abandoned", delegation(parent).error_key
    assert_empty child.conversation_inputs
    assert_equal "failed", call_node(parent).spawn_await.status
    assert_equal input.public_id, delegation(parent).delegated_input_public_id
    relay(child)
    assert_empty child.conversation_turns
  end

  test "the original no tools invocation supplies completion" do
    peer = create_agent_member(display_name: "Reviewer")
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn", agent: "@#{peer.handle}" })
    child, turn, child_loop = start_child(parent)
    assert_nil child_loop
    invocation = turn.active_variant.model_invocation
    ModelInvocations::AdmitQueuedWork.call
    attempt = invocation.attempts.order(:id).last
    apply_via(attempt, sse_success("one shot child report"))
    relay(child)
    assert_equal "completed", delegation(parent).reload.status
    assert_equal "Mock: one shot child report", delegation(parent).output_body.effective_text
  end

  # A declined reply completed its call and failed its work: the parent
  # reads the refusal as a failure, never an empty completion — and nothing
  # settles until the reply's converger has decided switch or stand.
  test "a refused no tools reply fails the delegation with the refusal" do
    peer = create_agent_member(display_name: "Reviewer")
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn", agent: "@#{peer.handle}" })
    child, turn, _child_loop = start_child(parent)
    invocation = turn.active_variant.model_invocation
    ModelInvocations::AdmitQueuedWork.call
    apply_via(invocation.attempts.order(:id).last, sse_refused("I can't help with that."))
    relay(child)
    assert_equal "running", delegation(parent).reload.status, "the reply's converger has not decided yet"

    Conversations::Turns::Converge.call(conversation_id: child.id)
    relay(child)

    settled = delegation(parent).reload
    assert_equal %w[failed model_refused], settled.values_at(:status, :error_key)
    assert_equal "(the reply ended failed: #{invocation.provider_id}/#{invocation.model_ref} declined it, so it has " \
                 "no text)\n#{AgentLoops::TaskResultEnvelope::DECLINED}", settled.output_body.effective_text,
      "the words the relayed reply and the wait tool read too"
  end

  # The peer's own declared fallback answers the original request: the
  # delegation waits for that sample and the parent reads its answer.
  test "a refused no tools reply the peer's fallback answers settles with the fallback's text" do
    peer = declare_tools!(create_agent_member(display_name: "Reviewer"), tools: [],
      fallback_model: "dev/mock-unmetered")
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn", agent: "@#{peer.handle}" })
    child, turn, _child_loop = start_child(parent)
    invocation = turn.active_variant.model_invocation
    ModelInvocations::AdmitQueuedWork.call
    apply_via(invocation.attempts.order(:id).last, sse_refused("I can't help with that."))
    Conversations::Turns::Converge.call(conversation_id: child.id)
    relay(child)
    assert_equal "running", delegation(parent).reload.status, "the fallback sample still runs"

    fallback = turn.reload.conversation_turn_variants.find_by!(source: "fallback").model_invocation
    ModelInvocations::AdmitQueuedWork.call
    apply_via(fallback.attempts.order(:id).last, sse_success("the fallback's report"))
    relay(child)

    settled = delegation(parent).reload
    assert_equal "completed", settled.status
    assert_equal "Mock: the fallback's report", settled.output_body.effective_text
  end

  # An overload on every attempt is the fallback's second trigger, so the
  # delegation holds exactly as for a refusal and reads the sample that
  # answered — never the `failed` the switch retracts.
  test "an overloaded no tools reply the peer's fallback answers settles with the fallback's text" do
    peer = declare_tools!(create_agent_member(display_name: "Reviewer"), tools: [],
      fallback_model: "dev/mock-unmetered")
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn", agent: "@#{peer.handle}" })
    child, turn, _child_loop = start_child(parent)
    overload_reply!(turn.active_variant.model_invocation)
    relay(child)
    assert_equal "running", delegation(parent).reload.status, "the reply's converger has not decided yet"

    Conversations::Turns::Converge.call(conversation_id: child.id)
    relay(child)
    assert_equal "running", delegation(parent).reload.status, "the fallback sample still runs"

    fallback = turn.reload.conversation_turn_variants.find_by!(source: "fallback").model_invocation
    ModelInvocations::AdmitQueuedWork.call
    apply_via(fallback.attempts.order(:id).last, sse_success("the fallback's report"))
    relay(child)

    settled = delegation(parent).reload
    assert_equal "completed", settled.status
    assert_equal "Mock: the fallback's report", settled.output_body.effective_text
  end

  test "an overloaded no tools reply with no fallback fails the delegation once its converger stood it" do
    peer = create_agent_member(display_name: "Reviewer")
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn", agent: "@#{peer.handle}" })
    child, turn, _child_loop = start_child(parent)
    overload_reply!(turn.active_variant.model_invocation)
    relay(child)
    assert_equal "running", delegation(parent).reload.status, "the reply's converger has not decided yet"

    Conversations::Turns::Converge.call(conversation_id: child.id)
    relay(child)

    settled = delegation(parent).reload
    assert_equal "failed", settled.status
    assert_equal "The delegated execution ended failed: provider_overloaded.", settled.output_body.effective_text
  end

  test "stopping the owner cancels the original no tools invocation" do
    peer = create_agent_member(display_name: "Reviewer")
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn", agent: "@#{peer.handle}" })
    child, turn, child_loop = start_child(parent)
    assert_nil child_loop
    invocation = turn.active_variant.model_invocation
    AgentLoops::Stop.stop_now(parent)
    assert_ladder_order("delegated invocation cleanup") { relay(child) }
    assert_equal "canceled", invocation.reload.status
    assert_equal "delegation_canceled", invocation.failure_reason_key
    assert turn.reload.relayed_at
    refute AgentLoops::Delegations.retained?(parent)
  end

  test "a finished child cannot be hard deleted before its report is durable in the parent" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn" })
    child, turn, child_loop = start_child(parent)
    run_round!(child_loop, "r1", "owed report")
    Conversations::Turns::Converge.call(conversation_id: child.id)
    command = Conversations::Turns::HardDelete::Command.new(
      conversation: child, turn_public_id: turn.public_id, acting_user: @agent)
    assert_equal :delegation_pending, Conversations::Turns::HardDelete.call(command).outcome
    relay(child)
    assert Conversations::Turns::HardDelete.call(command).accepted?
    assert_equal "Mock: owed report", delegation(parent).reload.output_body.effective_text
  end

  test "a stopped owner withdraws only its published input" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn" })
    child = child_of(parent)
    brief_id = delegation(parent).delegated_input_public_id
    post_input!(child, acting_user: @agent, text: "independent follow up")
    AgentLoops::Stop.stop_now(parent)
    assert AgentLoops::Delegations.retained?(parent)
    relay(child)
    refute child.conversation_inputs.exists?(public_id: brief_id)
    assert_equal ["independent follow up"], child.conversation_inputs.map(&:text)
    refute AgentLoops::Delegations.retained?(parent)
  end

  test "a child hold remains an outstanding completion obligation" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn" })
    child, turn, child_loop = start_child(parent)
    apply_via(attempt_for(child_loop, "r1"), json_response(400, { "error" => "held" }))
    AgentLoops::ConvergeTerminalSteps.call
    schedule_loop!(child_loop)
    Conversations::Turns::Converge.call(conversation_id: child.id)
    assert_equal "needs_attention", child_loop.reload.status
    assert_equal "failed", turn.reload.status
    relay(child)
    assert_equal "running", delegation(parent).reload.status
    assert_nil turn.reload.relayed_at
  end

  test "editing a held original stops that execution and preserves the replacement" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn" })
    child, turn, child_loop = start_child(parent)
    apply_via(attempt_for(child_loop, "r1"), json_response(400, { "error" => "held" }))
    AgentLoops::ConvergeTerminalSteps.call
    schedule_loop!(child_loop)
    Conversations::Turns::Converge.call(conversation_id: child.id)
    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: child, turn_public_id: turn.public_id, acting_user: @agent,
      entries: [{ "text" => "my replacement answer" }]))
    assert edited.accepted?

    relay(child)
    assert_equal "canceling", child_loop.reload.status
    assert_equal "running", delegation(parent).reload.status
    schedule_loop!(child_loop)
    relay(child)
    assert_equal "delegation_replaced", delegation(parent).reload.error_key
    assert_includes delegation(parent).output_body.effective_text, edited.value.public_id
    refute_includes delegation(parent).output_body.effective_text, "my replacement answer"
    assert_equal edited.value.id, turn.reload.active_variant_id
  end

  test "regeneration never retargets the original result or later owner cleanup" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn" })
    child, turn, child_loop = start_child(parent)
    run_round!(child_loop, "r1", "original report")
    Conversations::Turns::Converge.call(conversation_id: child.id)
    regenerated = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: child, turn_public_id: turn.public_id, acting_user: @agent,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil))
    assert regenerated.accepted?
    replacement = regenerated.value.agent_loop
    schedule_loop!(replacement)
    relay(child)
    assert_equal "Mock: original report", delegation(parent).reload.output_body.effective_text
    AgentLoops::Stop.stop_now(parent)
    relay(child)
    assert_equal "running", replacement.reload.status
    refute AgentLoops::Delegations.retained?(replacement)
  end

  test "canceling an owed original does not stop a later independent child request" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn" })
    child, _turn, child_loop = start_child(parent)
    run_round!(child_loop, "r1", "original report")
    Conversations::Turns::Converge.call(conversation_id: child.id)
    post_input!(child, acting_user: @agent, text: "new independent work", kind: "direct_reply",
      provider_id: "dev", model_ref: "mock-text")
    result = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert result.accepted?
    independent = result.value.active_variant.agent_loop
    schedule_loop!(independent)
    assert_equal "conversation", loop_node(independent, "r1").lifetime
    AgentLoops::Stop.stop_now(parent)
    assert_ladder_order("precise delegation cleanup") { relay(child) }
    assert_equal "running", independent.reload.status
    assert_equal "canceled", delegation(parent).reload.status
  end

  test "an unpublished launch whose call expires settles through recurring recovery" do
    parent, call = prepare_launch
    create = Conversations::Inputs::Create.method(:call)
    Conversations::Inputs::Create.stub(:call, ->(command) {
      raise "worker disappeared before publication" if command.delegation

      create.call(command)
    }) do
      assert_raises(RuntimeError) { AgentLoops::Spawn::Run.call(node: call) }
    end
    child = child_of(parent)
    assert_empty child.conversation_inputs
    assert_nil delegation(parent).delegated_input_public_id
    call.update_columns(await_started_at: 2.hours.ago)
    AgentLoops::Parks::Settle.call(node: call, timeout: true)
    schedule_loop!(parent)
    AgentLoops::Spawn::Relay.call
    assert_equal "failed", delegation(parent).reload.status
    assert_equal "delegation_launch_failed", delegation(parent).error_key
    assert_empty child.conversation_inputs
  end

  test "publication survives receipt expiry and consumption before a launch retry" do
    parent, call = prepare_launch
    AgentLoops::KernelTool.stub(:settle, ->(*) { raise "worker disappeared after publication" }) do
      assert_raises(RuntimeError) { AgentLoops::Spawn::Run.call(node: call) }
    end
    child = child_of(parent)
    published_id = child.conversation_inputs.sole.public_id
    assert_equal published_id, delegation(parent).delegated_input_public_id
    assert_ladder_order("delegated input materialization") { start_child(parent) }
    ConversationCommandReceipt.where(host: child).delete_all
    assert_empty child.conversation_inputs

    AgentLoops::Spawn::Run.call(node: call.reload)
    assert_equal "completed", call.reload.status
    assert_empty child.conversation_inputs
    assert_equal 1, child.conversation_turns.count
    assert_equal published_id, delegation(parent).reload.delegated_input_public_id
  end

  test "stopping the owner before publication refuses the late brief" do
    parent, call = prepare_launch
    create = Conversations::Inputs::Create.method(:call)
    Conversations::Inputs::Create.stub(:call, ->(command) {
      AgentLoops::Stop.stop_now(parent) if command.delegation
      create.call(command)
    }) do
      AgentLoops::Spawn::Run.call(node: call)
    end
    child = child_of(parent)
    assert_empty child.conversation_inputs
    assert_empty child.conversation_turns
    assert_nil delegation(parent).delegated_input_public_id
    assert_equal "canceled", delegation(parent).status
    relay(child)
    refute AgentLoops::Delegations.retained?(parent)
  end

  test "a stopped owner prevents materialization of its already published input" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn" })
    child = child_of(parent)
    AgentLoops::Stop.stop_now(parent)
    assert_ladder_order("stopped delegation input drain") do
      Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    end
    assert_empty child.conversation_inputs
    assert_empty child.conversation_turns
  end

  test "canceling only the short wait leaves completion and child execution outstanding" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn", wait: true })
    child, _turn, child_loop = start_child(parent)
    await = call_node(parent).spawn_await
    canceled = AgentLoops::CancelBranch.call(AgentLoops::CancelBranch::Command.new(
      agent_loop: parent, task_key: await.node_key, acting_user: @agent))
    assert canceled.accepted?
    relay(child)
    assert_equal "canceled", await.reload.status
    assert_equal "running", child_loop.reload.status
    assert_equal "running", delegation(parent).reload.status
    schedule_loop!(parent)
    run_round!(parent, "r2", "collecting later")
    run_round!(child_loop, "r1", "report after wait cancel")
    relay(child)
    schedule_loop!(parent)
    assert_equal 1, request_texts(parent, "w1").join.scan("report after wait cancel").length
    assert_equal "completed", delegation(parent).reload.status
  end

  test "nested turn cleanup preserves an explicit conversation lifetime grandchild" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn" })
    child, _turn, child_loop = start_child(parent)
    spawn_round!(child_loop, { prompt: "owned nested work" },
      { prompt: "independent nested work", lifetime: "conversation" })
    owned = child_of(child_loop)
    independent = child_of(child_loop, "r2t1")
    assert call_node(child_loop).spawn_delegation
    assert_nil call_node(child_loop, "r2t1").spawn_delegation
    AgentLoops::Stop.stop_now(parent)
    relay(child)
    relay(owned)
    relay(independent)
    assert_equal "canceling", child_loop.reload.status
    assert_empty owned.conversation_inputs
    assert_equal 1, independent.conversation_inputs.count
    refute independent.tombstoned?
  end

  test "an unrepresentable final report closes both wait and completion honestly" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn", wait: true })
    child, _turn, child_loop = start_child(parent)
    run_round!(child_loop, "r1", "valid report")
    replacement = ContentBodies::Replace.method(:call)
    ContentBodies::Replace.stub(:call, ->(**fields) {
      if fields.fetch(:owner).id.in?([delegation(parent).id, call_node(parent).spawn_await.id])
        ContentBodies::Replace::Result.refused(:unrepresentable)
      else
        replacement.call(**fields)
      end
    }) do
      relay(child)
    end
    assert_equal "failed", call_node(parent).spawn_await.reload.status
    assert_equal "delegation_result_unstorable", call_node(parent).spawn_await.error_key
    assert_equal "failed", delegation(parent).reload.status
    assert_equal "delegation_result_unstorable", delegation(parent).error_key
    schedule_loop!(parent)
    assert_equal "running", loop_node(parent, "r2").status
  end

  test "the source frontier continues past unfinished work within its own budget" do
    first = spawning_loop({ prompt: PROMPT, lifetime: "turn" })
    # The second caller needs its own idle conversation.
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    second = spawning_loop({ prompt: PROMPT, lifetime: "turn" })
    child, _turn, child_loop = start_child(second)
    run_round!(child_loop, "r1", "second report")
    pass = AgentLoops::Spawn::Relay.call(children_done: true, inputs_done: true, variants_done: true, budget: 1)
    assert pass.more?
    assert_equal 1, pass.counts.fetch(:scanned)
    assert_equal "running", delegation(first).reload.status
    assert_equal "running", delegation(second).reload.status
    continued = AgentLoops::Spawn::Relay.call(**pass.cursor.symbolize_keys, budget: 1)
    assert_equal 1, continued.counts.fetch(:scanned)
    assert_equal "completed", delegation(second).reload.status
    assert_equal "Mock: second report", delegation(second).output_body.effective_text
    assert child.conversation_turns.sole.relayed_at
  end

  test "duplicate child hint and source recovery publish one waited completion" do
    parent = spawning_loop({ prompt: PROMPT, lifetime: "turn", wait: true })
    child, turn, child_loop = start_child(parent)
    run_round!(child_loop, "r1", "concurrent child report")
    clear_enqueued_jobs
    held = hold_row_lock(AgentLoop, parent.id)
    calls = [
      start_database_call { relay(child) },
      start_database_call { AgentLoops::Spawn::Relay.call(children_done: true) },
    ]
    wait_until_transitively_blocked_by(held.pid, *calls.map(&:pid))
    release_row_lock(held)
    held = nil
    calls.each { |call| finish_database_call(call) }
    calls = []

    assert_equal "completed", delegation(parent).reload.status
    assert_equal 1, delegation(parent).content_bodies.where(role: "output").count
    assert_equal "completed", call_node(parent).spawn_await.reload.status
    assert turn.reload.relayed_at
    assert_empty ApplicationRecord.uncached { @conversation.conversation_inputs.to_a }
    schedule_loop!(parent)
    assert_equal 1, paired_results(parent, "r2").values.join.scan("concurrent child report").length
  ensure
    release_row_lock(held) if held
    calls&.each { |call| stop_database_call(call) }
    [child, @conversation].compact.each do |conversation|
      ConversationCommandReceipt.where(host: conversation).delete_all
      conversation.hosted_agent_loops.each do |agent_loop|
        UsageRecord.where(model_invocation_public_id: agent_loop.model_invocations.select(:public_id)).delete_all
        AgentLoops::Reap.destroy_aggregate(agent_loop)
      end
      conversation.reload.destroy!
    end
  end

  test "publication overlapping source reap commits no unowned input" do
    parent, call = prepare_launch
    invocation_ids = parent.model_invocations.pluck(:public_id)
    publication = nil
    Conversations::Inputs::Create.stub(:call, ->(command) {
      publication = command
      raise "pause before publishing"
    }) do
      assert_raises(RuntimeError) { AgentLoops::Spawn::Run.call(node: call) }
    end
    child = child_of(parent)
    source_public_id = parent.public_id
    held = hold_row_lock(AgentLoop, parent.id, before_commit: ->(source) {
      AgentLoops::Stop.stop_now(source)
      AgentLoops::Reap.destroy_aggregate(source)
    })
    writer = start_database_call { Conversations::Inputs::Create.call(publication) }
    # The writer owns the child while waiting for the source. Reap's actual
    # spawn_node foreign key must nullify that same child. PostgreSQL may
    # abort either transaction, but may not commit only half of publication.
    wait_until_transitively_blocked_by(held.pid, writer.pid)
    begin
      release_row_lock(held)
    rescue ActiveRecord::Deadlocked
      # This transaction rolled back, including its cancellation and delete.
    ensure
      held = nil
    end
    published = false
    begin
      published = finish_database_call(writer).accepted?
    rescue ActiveRecord::Deadlocked, ActiveRecord::RecordNotFound
      # Losing publication rolls its Input and publication UUID back together.
    ensure
      writer = nil
    end

    ApplicationRecord.uncached do
      source = AgentLoop.find_by(id: parent.id)
      if published
        assert source, "a committed input must retain its source"
        pending = child.conversation_inputs.sole
        assert_equal pending.public_id, delegation(source).delegated_input_public_id
        AgentLoops::Stop.stop_now(source)
        relay(child)
        assert_empty child.conversation_inputs.reload
        refute AgentLoops::Delegations.retained?(source)
        assert source.with_lock { AgentLoops::Reap.destroy_aggregate(source) }
      else
        assert_nil source
        assert_nil child.reload.spawn_node_id
        assert_not ConversationInput.exists?(sender_agent_loop_public_id: source_public_id)
      end
    end
    assert_not AgentLoop.exists?(parent.id)
  ensure
    release_row_lock(held) if held
    stop_database_call(writer) if writer
    UsageRecord.where(model_invocation_public_id: invocation_ids).delete_all if invocation_ids
    [child, @conversation].compact.each do |conversation|
      ConversationCommandReceipt.where(host: conversation).delete_all
      conversation.hosted_agent_loops.each do |agent_loop|
        AgentLoops::Stop.stop_now(agent_loop) unless agent_loop.terminal?
        AgentLoops::Reap.destroy_aggregate(agent_loop)
      end
      conversation.reload.destroy!
    end
  end
end
