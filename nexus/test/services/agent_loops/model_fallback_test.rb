require "test_helper"
require "test_helpers/invocation_result_test_helper"

# THE ANSWERER'S DECLARED SWITCH, two triggers and one write. A result
# receipt whose captured model is unavailable moves once per mail loop to
# the recipient's current different `default_model`; a step a provider's
# classifier refused moves once per step to the answerer's `fallback_model`.
# Both are bounded by the step's own history: neither ever returns a step to
# a model that already refused it.
class AgentLoops::ModelFallbackTest < ActiveJob::TestCase
  include InvocationHarness
  include InvocationResultTestHelper
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::STATUS], default_model: "dev/mock-unmetered")
  end

  test "mail whose original model vanished uses the receiving agent's different configured model" do
    source, text = queued_mail!(model_ref: "mock-windowless")
    remove_model!("dev/mock-windowless")

    mail_loop = drain_mail!
    assert_not_nil mail_loop, "unavailable mail must retain a recoverable model task"
    schedule_loop!(mail_loop)
    node = loop_node(mail_loop, "r1")
    assert_equal "mock-unmetered", node.model_ref
    assert_equal "running", node.status
    assert_predicate mail_loop.reload, :mail_model_fallback_used?
    assert_equal @agent.id, mail_loop.answering_user.id
    assert_equal source.approval_mode, mail_loop.approval_mode
    assert_equal text, mail_loop.conversation_turn_variant.content_bodies.find_by!(role: "prompt").effective_text
    assert_equal "mock-unmetered", mail_loop.conversation_turn_variant.model_ref, "the seed records its actual compilation model"

    finish!(mail_loop, "r1", "received")
    assert_equal "completed", mail_loop.reload.status
    assert_equal 0, @conversation.conversation_inputs.count
  end

  test "mail whose original model is hidden uses the receiving agent's different configured model" do
    queued_mail!
    policy = ModelProviderPolicy.find_by!(account: @account, provider_id: "dev")
    policy.set_model_visibility("dev/mock-text", visible: false)
    policy.save!

    mail_loop = drain_mail!
    schedule_loop!(mail_loop)

    assert_equal "mock-unmetered", loop_node(mail_loop, "r1").model_ref
    assert_predicate mail_loop.reload, :mail_model_fallback_used?
    finish!(mail_loop, "r1", "received")
    assert_equal "completed", mail_loop.reload.status
  end

  test "a provider access failure replaces only the failed mail round after completed tools" do
    queued_mail!
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    call!(mail_loop, "r1", "status", { to: @conversation.public_id })
    completed_tool = loop_node(mail_loop, "r2t0")
    assert_equal "completed", completed_tool.status
    original = loop_node(mail_loop, "r2").selected_model_invocation
    original_request = original.content_bodies.find_by!(role: "request").id

    apply_via(attempt_for(mail_loop, "r2"), json_response(403, { "error" => { "message" => "model access denied" } }))
    AgentLoops::ConvergeTerminalSteps.call
    schedule_loop!(mail_loop)

    current = loop_node(mail_loop, "r2")
    assert_equal "mock-unmetered", current.model_ref
    assert_equal "running", current.status
    assert_not_equal original.id, current.selected_model_invocation_id
    assert_equal "mock-text", original.reload.model_ref
    assert_equal original_request, original.content_bodies.find_by!(role: "request").id
    assert_equal "completed", completed_tool.reload.status
    assert_equal 0, completed_tool.execution_generation
    assert_equal 1, mail_loop.agent_loop_nodes.where(tool_name: completed_tool.tool_name).count
    finish!(mail_loop, "r2", "received after switching")
    assert_equal "completed", mail_loop.reload.status
  end

  test "tool-less mail holds after both models fail and retries only its failed node with an explicit model" do
    source, text = queued_mail! do
      declare_tools!(@agent, tools: [], default_model: "dev/mock-unmetered", approval_mode: nil)
    end

    mail_loop = drain_mail!
    assert_not_nil mail_loop, "a result receipt uses the same recoverable owner without tools"
    schedule_loop!(mail_loop)
    [401, 404].each do |status|
      apply_via(attempt_for(mail_loop, "r1"), json_response(status, { "error" => { "message" => "unavailable" } }))
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(mail_loop)
    end
    Conversations::Turns::Converge.call
    assert_equal "needs_attention", mail_loop.reload.status
    assert_equal "failed", mail_loop.conversation_turn.reload.status
    assert_equal text, mail_loop.conversation_turn_variant.content_bodies.find_by!(role: "prompt").effective_text
    assert_equal 2, mail_loop.model_invocations.count
    assert_empty loop_node(mail_loop, "r1").tool_definitions.to_a
    assert_equal source.approval_mode, mail_loop.approval_mode

    declare_tools!(@agent, tools: [], default_model: "dev/mock-windowless")
    2.times { schedule_loop!(mail_loop) }
    assert_equal 2, mail_loop.model_invocations.count, "a changed preset does not initiate a third switch"
    result = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: mail_loop, task_key: "r1", acting_user: @human,
      model: { "model" => "dev/mock-windowless" }
    ))
    assert_predicate result, :accepted?
    schedule_loop!(mail_loop)
    assert_predicate mail_loop.reload, :mail_model_fallback_used?
    finish!(mail_loop, "r1", "recovered")
    assert_equal "completed", mail_loop.reload.status
    assert_equal 3, mail_loop.model_invocations.count
  end

  test "a queued receipt whose inherited approval profile disappears degrades without blocking or losing the result" do
    _source, text = queued_mail! do
      declare_tools!(@agent, tools: [Nexus::Tools::TASK], approval_mode: "ask",
        default_model: "dev/mock-unmetered")
    end
    assert_nil @conversation.conversation_inputs.sole.approval_mode,
      "the source bypass mode does not tighten the current ask declaration"
    declare_tools!(@agent, tools: [], approval_mode: nil, default_model: "dev/mock-unmetered")

    assert_nil drain_mail!
    turn = @conversation.conversation_turns.order(:position).last
    assert_equal %w[message completed], [turn.kind, turn.status]
    assert_equal text, turn.active_variant.content_bodies.find_by!(role: "content").effective_text
    assert_empty @conversation.conversation_inputs.reload
    assert_nil @conversation.reload.active_turn_id
  end

  test "ordinary retry prepares a previously unavailable mail seed with the configured history budget" do
    source, text = queued_mail!(model_ref: "mock-windowless")
    declared = Users::DeclareConfiguration.call(user: @agent,
      tool_definitions: @agent.tool_definitions, approval_mode: @agent.approval_mode,
      approval_rules: nil, prompt_mechanism: "assembly", compaction_policy: nil,
      prompt_template: { "blocks" => [
        { "type" => "history", "budget" => { "share" => 0.0001 } }, { "type" => "input" },
      ] }, default_model: nil)
    assert_predicate declared, :accepted?
    remove_model!("dev/mock-windowless")
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    Conversations::Turns::Converge.call
    assert_equal "needs_attention", mail_loop.reload.status
    assert_nil loop_node(mail_loop, "r1").input_body
    assert_empty mail_loop.model_invocations
    assert_not_predicate mail_loop, :mail_model_fallback_used?

    @agent.update!(default_model: "dev/mock-unmetered")
    assert_predicate retry!(mail_loop), :accepted?
    schedule_loop!(mail_loop)
    node = loop_node(mail_loop, "r1")
    assert_equal "running", node.status
    seed = node.input_body
    assert_predicate seed, :sealed?
    assert_includes seed.effective_text, "background result"
    assert_not_includes seed.effective_text, "Mock: main answer", "the tiny template history budget still trims prior turns"
    event = trim_events(mail_loop).sole.payload
    assert_equal "budget_exceeded", event.fetch("history_skipped_reason")
    assert_operator event.fetch("history_skipped"), :>, 0
    assert_equal mail_loop.conversation_turn.public_id, event.fetch("turn_public_id")
    schedule_loop!(mail_loop)
    assert_equal 1, trim_events(mail_loop).count, "the prepared seed is not narrated twice"
    assert_equal source.approval_mode, mail_loop.approval_mode
    assert_predicate mail_loop.reload, :mail_model_fallback_used?
    finish!(mail_loop, "r1", "received after setup")
    assert_equal "completed", mail_loop.conversation_turn.reload.status
    assert_equal text, mail_loop.conversation_turn_variant.content_bodies.find_by!(role: "prompt").effective_text
  end

  test "both missing models leave no fabricated seed and a restored selected model can retry normally" do
    queued_mail!(model_ref: "mock-windowless")
    remove_model!("dev/mock-windowless")
    remove_model!("dev/mock-unmetered")
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    Conversations::Turns::Converge.call
    node = loop_node(mail_loop, "r1")
    assert_equal "mock-unmetered", node.model_ref
    assert_equal "failed", node.status
    assert_nil node.input_body
    assert_empty mail_loop.model_invocations
    assert_predicate mail_loop.reload, :mail_model_fallback_used?

    refused = retry!(mail_loop, model: { "model" => "dev/missing" })
    assert_not_predicate refused, :accepted?
    assert_equal 0, node.reload.execution_generation
    assert_nil node.input_body
    policy = ModelProviderPolicy.find_by!(account: @account, provider_id: "dev")
    policy.delete_entry("dev/mock-unmetered")
    policy.save!
    assert_predicate retry!(mail_loop), :accepted?
    schedule_loop!(mail_loop)
    assert_equal "running", node.reload.status
    assert_predicate node.input_body, :sealed?
    assert_equal 1, mail_loop.model_invocations.count
  end

  test "a refused deferred assembly keeps the original receipt and no partially prepared input" do
    queued_mail!(model_ref: "mock-windowless")
    declared = Users::DeclareConfiguration.call(user: @agent,
      tool_definitions: @agent.tool_definitions, approval_mode: @agent.approval_mode,
      approval_rules: nil, prompt_mechanism: "assembly", compaction_policy: nil,
      prompt_template: { "blocks" => [
        { "type" => "history", "budget" => { "share" => 0.5 } }, { "type" => "input" },
      ] }, default_model: nil)
    assert_predicate declared, :accepted?
    remove_model!("dev/mock-windowless")
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    Conversations::Turns::Converge.call
    prompt = mail_loop.conversation_turn_variant.content_bodies.find_by!(role: "prompt")
    policy = ModelProviderPolicy.find_by!(account: @account, provider_id: "dev")
    policy.delete_entry("dev/mock-windowless")
    policy.save!

    assert_predicate retry!(mail_loop), :accepted?
    schedule_loop!(mail_loop)
    node = loop_node(mail_loop, "r1")
    assert_equal "needs_attention", mail_loop.reload.status
    assert_equal "history_budget_unavailable", node.error_key
    assert_nil node.input_body
    assert_empty trim_events(mail_loop), "a refused preparation emits no successful trimming event"
    assert_empty mail_loop.model_invocations
    assert_predicate prompt.reload, :sealed?
    assert_predicate retry!(mail_loop, model: { "model" => "dev/mock-unmetered" }), :accepted?
    schedule_loop!(mail_loop)
    assert_equal "running", node.reload.status
    assert_predicate node.input_body, :sealed?
  end

  test "a later round does not get another automatic model switch" do
    queued_mail!
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    fail_round!(mail_loop, "r1", 401)
    assert_predicate mail_loop.reload, :mail_model_fallback_used?
    call!(mail_loop, "r1", "status", { to: @conversation.public_id })
    @agent.update!(default_model: "dev/mock-windowless")
    fail_round!(mail_loop, "r2", 403)
    assert_equal "needs_attention", mail_loop.reload.status
    assert_equal "mock-unmetered", loop_node(mail_loop, "r2").model_ref
    assert_equal 3, mail_loop.model_invocations.count
  end

  [nil, "dev/mock-text"].each do |preset|
    test "access failure does not switch when the recipient preset is #{preset.inspect}" do
      queued_mail!
      @agent.update!(default_model: preset)
      mail_loop = drain_mail!
      schedule_loop!(mail_loop)
      fail_round!(mail_loop, "r1", 401)
      assert_equal "needs_attention", mail_loop.reload.status
      assert_not_predicate mail_loop, :mail_model_fallback_used?
      assert_equal 1, mail_loop.model_invocations.count
    end
  end

  test "a deterministic request refusal and an explicitly selected branch never trigger fallback" do
    queued_mail!
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    fail_round!(mail_loop, "r1", 400)
    assert_equal "needs_attention", mail_loop.reload.status
    assert_not_predicate mail_loop, :mail_model_fallback_used?
    assert_predicate retry!(mail_loop), :accepted?
    schedule_loop!(mail_loop)
    call!(mail_loop, "r1", "task", { prompt: "explicit branch", wait: true })
    fail_round!(mail_loop, "r2t0-model-1", 403)
    assert_not_predicate mail_loop.reload, :mail_model_fallback_used?
    assert_equal "mock-text", loop_node(mail_loop, "r2t0-model-1").model_ref
  end

  test "canceling mail cannot spend its fallback allowance" do
    queued_mail!
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    attempt = attempt_for(mail_loop, "r1")
    stopped = AgentLoops::Stop.call(AgentLoops::Stop::Command.new(
      agent_loop: mail_loop, acting_user: @human, force: false))
    assert_predicate stopped, :accepted?
    apply_via(attempt, json_response(403, { "error" => { "message" => "unavailable" } }))
    AgentLoops::ConvergeTerminalSteps.call
    schedule_loop!(mail_loop)
    assert_equal "canceled", mail_loop.reload.status
    assert_not_predicate mail_loop, :mail_model_fallback_used?
    assert_equal 1, mail_loop.model_invocations.count
  end

  test "temporary provider errors exhaust the existing attempt budget before switching once" do
    assert_mail_rung_after(502, "attempt_budget_spent")
  end

  # An overload is transient first: the attempt budget runs out before any switch. With no
  # `fallback_model` declared the overload stands for the refusal's trigger, and the mail round
  # keeps its own rung: the recipient's `default_model`.
  test "an overload with no fallback declared spends the budget, then takes the mail rung" do
    assert_mail_rung_after(503, "provider_overloaded")
  end

  # BOTH RUNGS, in order: an overloaded mail round moves once to the declared fallback; when the
  # fallback is overloaded in turn the step's switch stands, and the mail rung takes the recipient's
  # default model — the loop's own allowance, spent once.
  test "an overloaded mail round moves to the fallback, and when that stands the mail rung takes the default" do
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::STATUS],
      default_model: "dev/mock-unmetered", fallback_model: "dev/mock-windowless")
    queued_mail!
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    overload_round!(mail_loop, "r1")
    assert_equal ["mock-windowless", "provider_overloaded"],
      [loop_node(mail_loop, "r1").model_ref, loop_node(mail_loop, "r1").output_summary.dig("model_change", "reason")]
    assert_not_predicate mail_loop.reload, :mail_model_fallback_used?

    overload_round!(mail_loop, "r1")

    assert_predicate mail_loop.reload, :mail_model_fallback_used?
    assert_equal "mock-unmetered", loop_node(mail_loop, "r1").model_ref
    assert_equal "provider_overloaded", loop_node(mail_loop, "r1").output_summary.dig("model_change", "reason"),
      "the row keeps the switch the step served"
  end

  test "a mail loop the unavailable rung moved configures its new work on the default model" do
    source, = queued_mail!(model_ref: "mock-windowless")
    remove_model!("dev/mock-windowless")
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    assert_equal "mock-unmetered", loop_node(mail_loop, "r1").model_ref
    assert_not_equal source.id, mail_loop.id

    assert_equal "dev/mock-unmetered", AgentLoops::ConfiguredModel.for(loop_node(mail_loop, "r1")).model.fetch("model"),
      "an unavailable model is no switch cause: nothing to return to"
  end


  # The switch is a ROW fact too, not narration alone: the requeued
  # execution's summary says what it replaced, at both sites the
  # unavailable trigger writes — a failed round, and the receipt's seed at
  # materialization — with no category, since nothing declined.
  test "the unavailable switch writes its row fact at the failed round and at the materialized seed" do
    queued_mail!
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    fail_round!(mail_loop, "r1", 401)

    switch = { "from" => "dev/mock-text", "reason" => "provider_model_unavailable" }
    assert_equal({ "model_change" => switch }, loop_node(mail_loop, "r1").output_summary)
    assert_equal [switch.merge("to" => "dev/mock-unmetered")], model_changes(mail_loop)
    finish!(mail_loop, "r1", "received")
    assert_equal({ "model_change" => switch }, loop_node(mail_loop, "r1").output_summary,
      "a completed switched step keeps what it replaced")

    queued_mail!(model_ref: "mock-windowless")
    remove_model!("dev/mock-windowless")
    seeded = drain_mail!
    narrated = model_changes(seeded).sole
    assert_equal %w[dev/mock-windowless dev/mock-unmetered], narrated.values_at("from", "to")
    assert_equal({ "model_change" => narrated.except("to") }, loop_node(seeded, "r1").output_summary)
  end

  # D refused the step and the switch moved it to F; F's lane then refuses
  # the resolver at its start. The mail rule's rung is D — the model that
  # refused — so there is no switch back, and the step fails with the
  # resolver's word instead of billing D a second refusal.
  test "the history bound: a fallback unavailable at its start never switches back to the model that refused" do
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::STATUS],
      default_model: "dev/mock-text", fallback_model: "dev/mock-windowless")
    queued_mail!
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    refuse_round!(mail_loop, "r1", schedule: false)
    assert_equal "mock-windowless", loop_node(mail_loop, "r1").model_ref
    assert_not_predicate mail_loop.reload, :mail_model_fallback_used?, "a refusal never spends the mail allowance"

    remove_model!("dev/mock-windowless")
    schedule_loop!(mail_loop)

    node = loop_node(mail_loop, "r1")
    assert_equal %w[failed unknown_model mock-windowless], node.values_at(:status, :error_key, :model_ref)
    assert_equal "dev/mock-text declined this step (cyber), so it failed with no output; the declared fallback " \
                 "model dev/mock-windowless cannot take this request (unknown_model), so nothing re-ran it",
      node.error_detail, "the start gate's word, beside the refusal the reader would otherwise never see"
    assert_equal 1, mail_loop.model_invocations.count, "the refusing model is never billed twice"
    assert_not_predicate mail_loop.reload, :mail_model_fallback_used?
  end

  # The mirror, at the switch: the fallback cannot take the step when the
  # refusal arrives, so nothing moves and the stand names the fallback and
  # the resolver's word for the reading model.
  test "a fallback the resolver refuses at the switch leaves the refusal standing, named" do
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::STATUS],
      default_model: "dev/mock-text", fallback_model: "dev/mock-windowless")
    queued_mail!
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    remove_model!("dev/mock-windowless")

    refuse_round!(mail_loop, "r1")

    node = loop_node(mail_loop, "r1")
    assert_equal %w[failed model_refused mock-text], node.values_at(:status, :error_key, :model_ref)
    assert_equal "dev/mock-text declined this step (cyber), so it failed with no output; the declared fallback " \
                 "model dev/mock-windowless cannot take this request (unknown_model), so nothing re-ran it",
      node.error_detail
    assert_equal 1, mail_loop.model_invocations.count
  end

  # A refusal's switch spends nothing of the mail allowance, so a later
  # unavailable fallback still gets the mail rule's one switch — to a model
  # that has not refused the step.
  test "after a refusal switch the unavailable trigger still switches once, to a model that has not refused" do
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::STATUS],
      default_model: "dev/mock-unmetered", fallback_model: "dev/mock-windowless")
    queued_mail!
    mail_loop = drain_mail!
    schedule_loop!(mail_loop)
    refuse_round!(mail_loop, "r1")
    assert_equal "mock-windowless", loop_node(mail_loop, "r1").model_ref

    fail_round!(mail_loop, "r1", 401)

    node = loop_node(mail_loop, "r1")
    assert_equal %w[running mock-unmetered], node.values_at(:status, :model_ref)
    refused_switch = { "from" => "dev/mock-text", "reason" => "model_refused", "category" => "cyber" }
    assert_equal({ "model_change" => refused_switch }, node.output_summary,
      "the row keeps the refusal it served; the later switch is the feed's")
    assert_predicate mail_loop.reload, :mail_model_fallback_used?
    assert_equal [%w[dev/mock-text dev/mock-windowless model_refused], %w[dev/mock-windowless dev/mock-unmetered
                                                                         provider_model_unavailable]],
      model_changes(mail_loop).map { |change| change.values_at("from", "to", "reason") }
    finish!(mail_loop, "r1", "received on the third model")
    assert_equal "completed", mail_loop.reload.status
    assert_equal({ "model_change" => refused_switch }, loop_node(mail_loop, "r1").output_summary)
  end

  private

    def trim_events(agent_loop)
      @conversation.conversation_event_items.where(item_type: "context_trimmed")
        .where("payload->>'agent_loop_public_id' = ?", agent_loop.public_id)
    end

    def retry!(agent_loop, model: nil)
      AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
        agent_loop: agent_loop, task_key: "r1", acting_user: @human, model: model))
    end

    # Every budgeted attempt of the mail round answers `status`; the budget spends as `key`, and
    # only then does the loop's one mail-rung switch move the round to the default model.
    def assert_mail_rung_after(status, key)
      queued_mail!
      mail_loop = drain_mail!
      schedule_loop!(mail_loop)
      original = loop_node(mail_loop, "r1").selected_model_invocation
      3.times do |index|
        fail_round!(mail_loop, "r1", status)
        if index < 2
          assert_not_predicate mail_loop.reload, :mail_model_fallback_used?
          ModelInvocation.where(id: original.id).update_all(next_admission_at: 1.second.ago)
        end
      end
      assert_equal [1, 2, 3], original.attempts.order(:ordinal).pluck(:ordinal)
      assert_equal key, original.reload.failure_reason_key
      assert_predicate mail_loop.reload, :mail_model_fallback_used?
      assert_equal "mock-unmetered", loop_node(mail_loop, "r1").model_ref
    end

    def overload_round!(agent_loop, key)
      invocation = loop_node(agent_loop, key).selected_model_invocation
      3.times do
        ModelInvocation.where(id: invocation.id).update_all(next_admission_at: 1.second.ago)
        fail_round!(agent_loop, key, 529)
      end
    end

    def fail_round!(agent_loop, key, status)
      apply_via(attempt_for(agent_loop, key), json_response(status, { "error" => { "message" => "unavailable" } }))
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(agent_loop)
    end

    def queued_mail!(model_ref: "mock-text")
      _turn, source = materialize_loop_reply!(@conversation, agent: @agent, text: "check in the background", model_ref: model_ref)
      schedule_loop!(source)
      call!(source, "r1", "task", { prompt: "background answer" })
      finish!(source, "r2", "main answer")
      finish!(source, "r2t0-model-1", "background result")
      yield if block_given?
      assert_equal [:mailed], AgentLoops::Mail.call(source.reload)
      [source, @conversation.conversation_inputs.sole.text]
    end

    def drain_mail!
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
    end

    def attempt_for(agent_loop, key)
      node = loop_node(agent_loop, key)
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      ModelInvocationAttempt.where(model_invocation_id: node.selected_model_invocation_id).order(:id).last
    end

    def call!(agent_loop, key, name, arguments)
      calls = [{ id: "call_#{key}", name: name, arguments: arguments.to_json }]
      apply_via(attempt_for(agent_loop, key), sse_success("working", tool_calls: calls))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ConversationToolJob, AgentLoops::ScheduleJob]) do
        schedule_loop!(agent_loop)
      end
    end

    def finish!(agent_loop, key, text)
      apply_via(attempt_for(agent_loop, key), sse_success(text))
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(agent_loop)
      Conversations::Turns::Converge.call
    end

    # The Anthropic shape, the lane whose refusal names its category.
    def refuse_round!(agent_loop, key, schedule: true)
      refused = SimpleInference::Protocols::AnthropicMessages.new(
        base_url: "https://api.anthropic.com", api_key: "secret",
        adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
          "id" => "msg_1", "content" => [], "stop_reason" => "refusal",
          "stop_details" => { "category" => "cyber", "explanation" => "No." },
          "usage" => { "input_tokens" => 2, "output_tokens" => 1 },
        }))
      ).create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)
      apply_provider_result(attempt_for(agent_loop, key), refused, adapter_profile: "anthropic_messages")
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      schedule_loop!(agent_loop) if schedule
    end

    def model_changes(agent_loop)
      @conversation.conversation_event_items.where(item_type: "task_status")
        .where("payload->>'agent_loop_public_id' = ?", agent_loop.public_id).order(:sequence)
        .filter_map { |item| item.payload["model_change"] }
    end

    def remove_model!(ref)
      policy = ModelProviderPolicy.find_by!(account: @account, provider_id: "dev")
      policy.put_entry(ref, { "op" => "remove" })
      policy.save!
    end
end
