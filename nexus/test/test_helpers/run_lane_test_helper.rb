# The loop-backed lane through the REAL chain: a tool-bearing agent's `direct_reply` head
# materializes a loop born running, the scheduler mints its rounds, and the harness applies them.
# Includers carry InvocationHarness and ActiveJob::TestHelper (the rounds enqueue).
module RunLaneTestHelper
  READ_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_file", "parameters" => { "type" => "object" } },
  }.freeze
  # The claude preset's spelling of `task`: an ALIAS entry in the compact input shape —
  # `run_in_background` inverted onto `wait`.
  AGENT_SENTENCE = "true (the default): the task runs in the background and its answer is delivered " \
    "to you in a later message. false: this turn waits and the answer is this call's result.".freeze
  AGENT_ALIAS = {
    "type" => "function", "function" => { "name" => "Agent" }, "canonical" => "nexus.graph.delegate_task",
    "params" => { "run_in_background" => { "maps_to" => "wait", "invert" => true, "description" => AGENT_SENTENCE } },
  }.freeze

  # The declaration AND the announcement, as rho makes them from one registry: what the model sees,
  # and what the agent's own address serves — with a transport credential, since addressing asks the
  # address for eligibility. The loop-backed lane's calls are thereby addressed to the agent
  # application.
  def declare_tools!(agent, tools: [READ_TOOL], compaction_policy: nil, approval_mode: "bypass",
                     approval_rules: nil, default_model: nil, fallback_model: nil)
    outcome = Users::DeclareConfiguration.call(user: agent,
      tool_definitions: tools, approval_mode: approval_mode, approval_rules: approval_rules,
      prompt_mechanism: nil, prompt_template: nil, compaction_policy: compaction_policy,
      default_model: default_model, fallback_model: fallback_model
    )
    assert_equal :declared, outcome.outcome
    announce_tools!(agent, tools.map { |tool| tool.dig("function", "name") })
    agent
  end

  # The declaration minus the kernel's own names: an executor serves what
  # it runs, and no lane here exercises the admitted-overridable path.
  def announce_tools!(agent, names)
    address = TaskExecutor.address_for(agent)
    return if address.nil?

    names = names.reject { |name| Nexus::ToolRegistry.kernel_name?(name) }

    unless TaskExecutor.credential_readiness_for([address]).fetch(address.id) == :ready
      create_bound_credential(executor: address, name: "Lane transport")
    end
    announced = address.announce(tools: names.map { |name|
      { "name" => name, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }
    })
    assert_predicate announced, :accepted?, announced.detail.to_s
  end

  def post_input!(conversation, acting_user:, text:, kind: "message", delivery_mode: "queue",
                  provider_id: nil, model_ref: nil, context_mode: nil, context_options: nil,
                  request_options: nil, tool_names: nil, answering_user_public_id: nil, steps: nil)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: conversation, acting_user: acting_user, kind: kind, role: "user",
      entries: text ? [{ "text" => text }] : [], visible_in_context: true, delivery_mode: delivery_mode,
      context_mode: context_mode, context_options: context_options, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: provider_id, model_ref: model_ref,
      reasoning_effort: nil, request_options: request_options, tool_names: tool_names,
      answering_user_public_id: answering_user_public_id, steps: steps
    ))
    assert_predicate result, :accepted?
    result.value
  end

  # The agent's reply head drained: the loop-backed turn and the loop behind it, born running with
  # round one queued for the scheduler. A nil `text` replies to the timeline as it stands (the
  # person's words are message turns); a text is the reply's own prompt — never a turn, but kept on
  # the variant and rendered by later history as the turn's seed.
  def materialize_loop_reply!(conversation, agent:, text: "what is up", **over)
    post_input!(conversation, acting_user: agent, kind: "direct_reply", text: text,
      provider_id: "dev", model_ref: "mock-text", **over)
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    turn = conversation.conversation_turns.order(:position).last
    assert_equal "run", turn.active_variant.source, "a tool-bearing head is a loop"
    [turn, turn.active_variant.agent_run]
  end

  def schedule_loop!(agent_run)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def loop_attempt(agent_run)
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
      candidate.attempt.model_invocation.agent_run_id == agent_run.id
    end
    raise "round not admitted" if admitted.nil?

    clear_enqueued_jobs
    admitted.attempt
  end

  # Apply the running round, converge it, and let the scheduler expand or
  # settle the loop — one whole round of the real chain.
  def run_loop_round!(agent_run, behaviour)
    apply_via(loop_attempt(agent_run), behaviour)
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule_loop!(agent_run)
  end

  def loop_node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  # The sealed request behind an invocation: the entries' payloads in order.
  def sealed_request_entries(invocation)
    invocation.content_bodies.find_by!(role: "request")
      .content_body_entries.map { |entry| entry.content_fragment.payload }
  end

  def round_request_entries(node)
    sealed_request_entries(ModelInvocation.find(node.selected_model_invocation_id))
  end
end
