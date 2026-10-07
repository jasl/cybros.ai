require "test_helper"

# `spawn`: a conversation with another agent — a fresh copy of the caller (a subagent) or a named
# peer — that PERSISTS. The child hangs off the parent CONVERSATION (never a branch or a node),
# names the call that minted it (`spawn_node_id`, the unique recovery key), copies the parent's
# access carrier, billing pair and runner, and is answered by the chosen profile through the
# conversation input door. The brief is the spawner's own row on the child (`Command.sent`, origin
# `agent`, the parent's stamp); `wait: true` parks a KERNEL-HELD await under the round's
# continuation — zero new states, the tokened `dispatched` word — whose expiry is detach + notify,
# never halt. Driven through the REAL chain: the round's call, the approval stage, the one
# conversation-tool job, the child's door.
class AgentRuns::SpawnTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper
  include AgentMembershipTestHelper

  PROMPT = "Review app/models/user.rb for N+1 queries and keep the findings; I will ask follow-ups.".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::SPAWN, READ_TOOL])
  end

  def say!(text) = post_input!(@conversation, acting_user: @human, text: text)

  def open_turn!(text = "go")
    say!(text)
    turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(agent_run)
    [turn, agent_run]
  end

  def attempt_for(agent_run, key)
    invocation_id = loop_node(agent_run, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  # The running round answers with `spawn` calls; the kernel's jobs run.
  def spawn_round!(agent_run, *calls, key: "r1")
    tool_calls = calls.each_with_index.map do |fields, index|
      { id: "call_#{index}", name: "spawn", arguments: fields.to_json }
    end
    apply_via(attempt_for(agent_run, key), sse_success("delegating", tool_calls: tool_calls))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentRuns::ConversationToolJob, AgentRuns::ScheduleJob]) do
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    end
    agent_run.reload
  end

  def run_round!(agent_run, key, text)
    apply_via(attempt_for(agent_run, key), sse_success(text))
    AgentRuns::ConvergeTerminalSteps.call
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    agent_run.reload
  end

  def spawning_loop(*calls)
    _turn, agent_run = open_turn!
    spawn_round!(agent_run, *calls)
  end

  def call_node(agent_run, key = "r2t0") = loop_node(agent_run, key)
  def child_of(agent_run, key = "r2t0") = Conversation.find_by(spawn_node_id: call_node(agent_run, key).id)
  def tool_result(agent_run, key) = loop_node(agent_run, key).content_bodies.find_by(role: "output")&.effective_text

  def sources_of(agent_run, key)
    loop_node(agent_run, key).incoming_edges.includes(:from_node).map { |edge| edge.from_node.node_key }.sort
  end

  def paired_results(agent_run, key)
    round_request_entries(loop_node(agent_run, key)).select { |payload| payload["type"] == "tool_result_item" }
      .to_h { |payload| [payload.dig("payload", "call_id"), payload.dig("payload", "output")] }
  end

  def request_texts(agent_run, key)
    round_request_entries(loop_node(agent_run, key)).filter_map { |payload| payload.dig("parts", 0, "text") }
  end

  def spawn_envelope(call, status, child, text)
    "<task_result task=\"#{call}\" status=\"#{status}\" conversation=\"#{child.public_id}\">\n#{text}\n</task_result>"
  end

  # ── the child ────────────────────────────────────────────────────────

  test "a detached spawn mints a subagent conversation off the parent, briefed by the spawner, and answers at once" do
    agent_run = spawning_loop({ prompt: PROMPT })
    assert_includes performed_jobs.map { |job| job.fetch(:job) }, AgentRuns::ConversationToolJob,
      "the approval stage hands the call to the one conversation-tool job"
    child = child_of(agent_run)

    assert_not_nil child, "the child names the call that minted it"
    assert_equal [@conversation.id, @conversation.public_id],
      [child.parent_conversation_id, child.parent_conversation_public_id], "the child hangs off the CONVERSATION"
    assert_predicate child, :subagent?
    assert_equal [@agent, @agent], [child.creating_user, child.answering_user],
      "the spawner is the creator; without `agent` it answers itself — a fresh copy with an empty context"
    assert_equal @workspace, child.workspace
    assert_nil child.spawn_label
    assert_includes Conversations::SubagentTree.member_ids(@conversation), child.id, "archive/tombstone stamp the tree"
    assert_equal({ @human.id => "full" }, child.conversation_access_entries.pluck(:user_id, :level).to_h,
      "the parent's derived-full creator is materialized; the child's own derived pair never holds a row")
    assert_equal "full", child.access_default
    assert_equal 0, ConversationInput.where(host: child).where.not(sender_conversation_public_id: @conversation.public_id).count

    brief = ConversationInput.where(host: child).sole
    assert_equal %w[direct_reply user queue pending agent], [brief.kind, brief.role, brief.delivery_mode, brief.state, brief.origin],
      "the brief is the spawner's own word: a reply head, origin `agent`, never a kernel receipt"
    assert_equal @agent, brief.authoring_user
    assert_equal @conversation.public_id, brief.sender_conversation_public_id, "the parent's stamp rides the row"
    assert_equal PROMPT, brief.text
    assert_equal %w[dev mock-text], [brief.provider_id, brief.model_ref],
      "the brief names its engine: the spawning turn's frozen selection, as kernel mail does"
    assert_nil brief.tool_names, "the spawner's per-turn tightening never crosses"
    assert_nil brief.approval_mode
    payload = child.conversation_event_items.where(item_type: "input_accepted").sole.payload
    assert_equal [agent_run.public_id, "r2t0"], payload.values_at("run_public_id", "task_key")
    assert_enqueued_with(job: Conversations::Inputs::DrainJob, args: [child.id])

    call = call_node(agent_run)
    assert_equal "completed", call.status
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "r2t0-spawn-1"), "detached: no await"
    assert_equal %w[r2t0], sources_of(agent_run, "r2"), "the continuation waits on the call alone"
    text = tool_result(agent_run, "r2t0")
    assert_equal "Spawned conversation #{child.public_id}, answered by @#{@agent.handle}, in the background. " \
      "Its reply reaches you as <task_result task=\"r2t0\" conversation=\"#{child.public_id}\"> in a later " \
      "message that is not from the person. send it more, read its status, or cancel it by that id.\n" \
      "Task reference: run_public_id=\"#{agent_run.public_id}\", task=\"r2t0\".", text
    assert_nil call.spawn_await
    assert_equal child, call.reload.spawned_conversation
  end

  test "the child's first turn is the answerer's engine replying to the brief" do
    agent_run = spawning_loop({ prompt: PROMPT })
    child = child_of(agent_run)

    Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    turn = child.conversation_turns.order(:position).last
    assert_equal %w[direct_reply assistant run], [turn.kind, turn.role, turn.active_variant.source],
      "a tool-bearing answerer's brief materializes a loop-backed reply on the child"
    assert_equal @conversation.public_id, turn.sender_conversation_public_id
    assert_equal @agent, turn.active_variant.agent_run.answering_user
  end

  test "the parent's billing pair and frozen default are copied and an ineligible inherited Runner refuses birth" do
    subject = BillingSubject.create!(account: @account, owning_user: @human, key: "team-a")
    wide = connect_runner(manager: users(:owner), registration_identifier: "wide-1",
      assignment_scope: :account_wide).executor_access_token.task_executor
    @agent.update!(runner_executor_public_ids: [wide.public_id])
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent,
      billing_subject_key: subject.key, billing_subject_public_id: subject.public_id, default_runner_executor: wide)
    agent_run = spawning_loop({ prompt: PROMPT })
    child = child_of(agent_run)

    assert_equal [subject.key, subject.public_id], [child.billing_subject_key, child.billing_subject_public_id]
    assert_equal wide, child.default_runner_executor, "the parent's bound runner, eligible for the child's answerer"

    private_runner = connect_runner(manager: users(:owner), registration_identifier: "private-1",
      assignment_scope: :user_private).executor_access_token.task_executor
    @agent.update!(runner_executor_public_ids: [private_runner.public_id])
    peer = create_agent_member(steward: @human, agent_identifier: "private-runner-peer")
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent,
      default_runner_executor: private_runner)
    agent_run = spawning_loop({ prompt: PROMPT, agent: peer.public_id })
    child = child_of(agent_run)
    assert_nil child
    assert_includes tool_result(agent_run, "r2t0"), "runner_not_eligible"
  end

  test "spawn inherits its originating default after a host change and honors explicit clear or replacement" do
    original = connect_runner(manager: users(:owner), registration_identifier: "spawn-original",
      assignment_scope: :account_wide).executor_access_token.task_executor
    replacement = connect_runner(manager: users(:owner), registration_identifier: "spawn-replacement",
      assignment_scope: :account_wide).executor_access_token.task_executor
    [original, replacement].each do |executor|
      executor.announce(tools: [{ "name" => "bash", "description" => "Execute on #{executor.public_id}",
        "input_schema" => { "type" => "object" }, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }],
        environment: { "fragments" => [{ "text" => "Workspace #{executor.public_id}" }] })
    end
    @agent.update!(runner_executor_public_ids: [original.public_id, replacement.public_id])
    @conversation.update!(default_runner_executor: original)
    _turn, agent_run = open_turn!
    assert_predicate Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
      host: @conversation, executor_public_id: replacement.public_id, acting_user: @human
    )), :accepted?

    spawn_round!(agent_run, { prompt: PROMPT }, { prompt: PROMPT, default_runner_executor_public_id: nil },
      { prompt: PROMPT, default_runner_executor_public_id: replacement.public_id })

    assert_equal original, child_of(agent_run, "r2t0").default_runner_executor
    assert_nil child_of(agent_run, "r2t1").default_runner_executor
    assert_equal replacement, child_of(agent_run, "r2t2").default_runner_executor
    assert_equal replacement, @conversation.reload.default_runner_executor

    [original, nil, replacement].each_with_index do |executor, index|
      child = child_of(agent_run, "r2t#{index}")
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
      seed = child.conversation_turns.last.active_variant.agent_run.agent_run_tasks.find_by!(node_key: "r1")
      route = seed.tool_definitions.find { |entry| entry.dig("route", "tool_name") == "bash" }
      if executor
        assert_equal executor.public_id, route.dig("route", "runner_executor_public_id")
        assert_equal executor.public_id, seed.operation_context.dig("environment", "default_runner_executor_public_id")
        assert_includes seed.input_body.effective_text, "Workspace #{executor.public_id}"
      else
        assert_nil route
        assert_nil seed.operation_context.dig("environment", "default_runner_executor_public_id")
      end
    end
  end

  test "agent names a peer by handle or id: its engine answers, the spawner stays the creator" do
    peer = create_agent_member(display_name: "Reviewer", agent_identifier: "reviewer-1")
    agent_run = spawning_loop({ prompt: PROMPT, agent: "@#{peer.handle}" }, { prompt: PROMPT, agent: peer.public_id })

    by_handle, by_id = child_of(agent_run, "r2t0"), child_of(agent_run, "r2t1")
    assert_equal [peer, peer], [by_handle.answering_user, by_id.answering_user]
    assert_equal [@agent, @agent], [by_handle.creating_user, by_id.creating_user]
    assert_equal({ @human.id => "full" }, by_handle.conversation_access_entries.pluck(:user_id, :level).to_h,
      "the parent's answerer is the child's creator — derived, never a row")
    assert_match(/answered by @#{peer.handle}, in the background/, tool_result(agent_run, "r2t0"))
    brief = ConversationInput.where(host: by_handle).sole
    assert_equal @agent, brief.authoring_user, "the brief is the SPAWNER's word on the peer's conversation"
  end

  test "a label names the child, normalized, unique among the parent's children" do
    agent_run = spawning_loop({ prompt: PROMPT, label: " Reviewer " }, { prompt: PROMPT, label: "reviewer" },
      { prompt: PROMPT, label: "Not a label!" })

    assert_equal "reviewer", child_of(agent_run, "r2t0").spawn_label
    assert_match(/\ASpawned conversation #{child_of(agent_run, "r2t0").public_id} \(label reviewer\), answered by/,
      tool_result(agent_run, "r2t0"))
    assert_nil child_of(agent_run, "r2t1"), "the same label under one parent is refused"
    assert loop_node(agent_run, "r2t1").output_summary["is_error"]
    assert_match(/label/, tool_result(agent_run, "r2t1"))
    assert_nil child_of(agent_run, "r2t2")
    assert_equal AgentRuns::Spawn::Run::INVALID_LABEL, tool_result(agent_run, "r2t2")
  end

  # THE MODEL THE BRIEF CARRIES: the initiator's — the call's `model`, else the spawning turn's —
  # read by the child's answerer only when it has no preset of its own; a peer with one answers on
  # it whatever the spawner named.
  test "a named model rides the brief when the answerer has no preset; the answerer's own default_model beats it" do
    peer = create_agent_member(display_name: "Reviewer", agent_identifier: "reviewer-1")
    declare_tools!(peer, tools: [READ_TOOL], default_model: "dev/mock-windowless")
    agent_run = spawning_loop({ prompt: PROMPT, model: "dev/mock-unmetered" },
      { prompt: PROMPT, agent: "@#{peer.handle}", model: "dev/mock-unmetered" })

    named = ConversationInput.where(host: child_of(agent_run, "r2t0")).sole
    assert_equal ["dev", "mock-unmetered", nil], [named.provider_id, named.model_ref, named.reasoning_effort],
      "the subagent has no preset: the call's `model`, at the model's own reasoning default"
    preset = ConversationInput.where(host: child_of(agent_run, "r2t1")).sole
    assert_equal ["dev", "mock-windowless", nil], [preset.provider_id, preset.model_ref, preset.reasoning_effort],
      "the peer's own default_model is step 0: it beats the model the spawner named"
    refute loop_node(agent_run, "r2t0").output_summary["is_error"]
  end

  # THE NAMED DEFINITION AS ANSWERER: a row the spawner's own instance declared resolves by handle
  # like any peer — `spawn`'s resolution and sentences are UNCHANGED; a removed one is still FOUND
  # by handle (`addressed_by` is not filtered on status) and answers `answerer_not_eligible`'s
  # sentence, a misspelled one `principal_unknown`.
  def declare_reviewer!
    Users::DeclareNamedDefinition.call(caller: @agent, name: "reviewer", scope: "instance",
      description: "Reviews a diff.", system_prompt: "You are the reviewer.",
      configuration: { tool_definitions: [READ_TOOL], approval_mode: "bypass", approval_rules: nil,
                       prompt_mechanism: "default", prompt_template: nil, compaction_policy: nil, default_model: nil })
      .user
  end

  test "a named definition answers a spawn by handle: the child runs under the named row's declaration" do
    reviewer = declare_reviewer!
    agent_run = spawning_loop({ prompt: PROMPT, agent: "@reviewer" })

    child = child_of(agent_run)
    assert_equal [reviewer, @agent], [child.answering_user, child.creating_user]
    assert_equal reviewer, child.declaring_profile, "the child runs under the NAMED row's whole declaration"
    assert_equal %w[read_file], Nexus::ToolDeclarations.names(child.declaring_profile.tool_definitions)
    assert_match(/answered by @reviewer, in the background/, tool_result(agent_run, "r2t0"))
  end

  test "a removed named definition is still found by handle and refused; a misspelled one is unknown" do
    reviewer = declare_reviewer!
    assert_equal :removed, reviewer.remove
    agent_run = spawning_loop({ prompt: PROMPT, agent: "@reviewer" }, { prompt: PROMPT, agent: "@reveiwer" })
    assert_equal "agent: @reviewer cannot answer a conversation here: it is not an agent profile " \
      "with write standing in this workspace.", tool_result(agent_run, "r2t0")
    unknown = tool_result(agent_run, "r2t1")
    assert_match(/\Aagent: "@reveiwer" names no member of this account\. The agents are: /, unknown)
    assert_includes unknown, "@#{@agent.handle}"
    assert_not_includes unknown, "@reviewer", "a removed row is not among the agents it could have named"
  end

  # ── refusals ─────────────────────────────────────────────────────────

  test "a model this account may not run is refused at the call with the resolver's word, and mints nothing" do
    agent_run = spawning_loop({ prompt: PROMPT, model: "dev/no-such-model" }, { prompt: PROMPT, model: "mock-text" },
      { prompt: PROMPT, model: 7 })

    assert_equal 'model_not_authorized: model: "dev/no-such-model" is not a model you may run here (unknown_model).',
      tool_result(agent_run, "r2t0")
    assert_equal 'model_not_authorized: model: "mock-text" is not a model you may run here (unknown_model).',
      tool_result(agent_run, "r2t1"), "a bare word is no catalog ref"
    assert_equal "model must be a string, as provider/model.", tool_result(agent_run, "r2t2")
    assert %w[r2t0 r2t1 r2t2].all? { |key| loop_node(agent_run, key).output_summary["is_error"] }
    assert_equal 0, Conversation.where.not(spawn_node_id: nil).count, "a refusal mints nothing"
  end

  test "an empty prompt, a wait that is not a boolean, an unknown agent and a Human agent are refused by sentence" do
    agent_run = spawning_loop({ prompt: "  " }, { prompt: PROMPT, wait: "yes" },
      { prompt: PROMPT, agent: "@nobody" }, { prompt: PROMPT, agent: "@#{@human.handle}" })

    assert_equal AgentRuns::Spawn::Run::EMPTY_PROMPT, tool_result(agent_run, "r2t0")
    assert_equal AgentRuns::KernelTool::INVALID_WAIT, tool_result(agent_run, "r2t1")
    unknown = tool_result(agent_run, "r2t2")
    assert_match(/\Aagent: "@nobody" names no member of this account\. The agents are: /, unknown)
    assert_includes unknown, "@#{@agent.handle}"
    assert_equal "agent: @#{@human.handle} cannot answer a conversation here: it is not an agent profile " \
      "with write standing in this workspace.", tool_result(agent_run, "r2t3")
    assert %w[r2t0 r2t1 r2t2 r2t3].all? { |key| loop_node(agent_run, key).output_summary["is_error"] }
    assert_equal 0, Conversation.where.not(spawn_node_id: nil).count, "a refusal mints nothing"
    refute_predicate loop_node(agent_run, "r2"), :terminal?, "one bad call never fails the round"
  end

  test "a side conversation cannot spawn" do
    Conversation.where(id: @conversation.id).update_all(side: true)
    agent_run = spawning_loop({ prompt: PROMPT })

    assert_equal AgentRuns::Spawn::Run::SIDE_SPAWNER, tool_result(agent_run, "r2t0")
    assert_nil child_of(agent_run)
  end

  test "a standalone loop refuses spawn with one sentence" do
    agent_run = seed(model("round1", "prompt" => "go", "tools" => [Nexus::Tools::SPAWN, READ_TOOL]))
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    spawn_round!(agent_run, { prompt: PROMPT }, key: "round1")

    assert_equal AgentRuns::Spawn::Run::NO_CONVERSATION, tool_result(agent_run, "r1t0")
    assert loop_node(agent_run, "r1t0").output_summary["is_error"]
    assert_equal 0, Conversation.where.not(spawn_node_id: nil).count
  end

  # ── recovery: the job may run twice ──────────────────────────────────

  test "a retried spawn does not repeat a brief the child already materialized" do
    _turn, agent_run = open_turn!
    apply_via(attempt_for(agent_run, "r1"), sse_success("delegating", tool_calls: [
      { id: "call_0", name: "spawn", arguments: { prompt: PROMPT }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    call = call_node(agent_run)
    interrupted = ->(*) { raise IOError, "settlement interrupted" }
    AgentRuns::KernelTool.stub(:settle, interrupted) do
      assert_raises(IOError) { AgentRuns::ConversationToolJob.perform_now(call.id) }
    end
    child = child_of(agent_run)
    assert_equal "running", call.status
    assert_equal 1, child.conversation_inputs.count

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    assert_empty child.conversation_inputs
    turn = child.conversation_turns.sole
    assert_equal @conversation.public_id, turn.sender_conversation_public_id

    assert_no_difference "child.conversation_inputs.count" do
      AgentRuns::ConversationToolJob.perform_now(call.id)
    end
    assert_equal "completed", call.reload.status
    assert_equal [turn.id], child.conversation_turns.pluck(:id)
  end

  test "a retry before the input door resumes with the existing child and await" do
    _turn, agent_run = open_turn!
    apply_via(attempt_for(agent_run, "r1"), sse_success("delegating", tool_calls: [
      { id: "call_0", name: "spawn", arguments: { prompt: PROMPT, wait: true }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    call = call_node(agent_run)
    interrupted = ->(*) { raise IOError, "input acceptance interrupted" }
    Conversations::Inputs::Create.stub(:call, interrupted) do
      assert_raises(IOError) { AgentRuns::ConversationToolJob.perform_now(call.id) }
    end
    child = child_of(agent_run)
    assert_equal "running", call.status
    assert_empty child.conversation_inputs
    assert_equal 1, agent_run.agent_run_tasks.where(node_key: "r2t0-spawn-1").count
    assert_not ConversationCommandReceipt.exists?(host: child)

    assert_no_difference ["Conversation.count", "AgentRunTask.count"] do
      AgentRuns::ConversationToolJob.perform_now(call.id)
    end
    assert_equal "completed", call.reload.status
    assert_equal PROMPT, child.conversation_inputs.sole.text
    assert_equal 1, ConversationCommandReceipt.where(host: child).count
  end

  test "a second run reuses the child and does not repeat a pending or deleted accepted brief" do
    agent_run = spawning_loop({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)
    call = call_node(agent_run)
    AgentRunTask.where(id: call.id).update_all(status: "running", completed_at: nil)

    assert_equal :applied, AgentRuns::Spawn::Run.call(node: call.reload)
    assert_equal 1, Conversation.where.not(spawn_node_id: nil).count, "ONE child per call"
    assert_equal 1, ConversationInput.where(host: child).count, "ONE brief"
    assert_equal 1, agent_run.agent_run_tasks.where(node_key: "r2t0-spawn-1").count, "ONE await"

    deleted = Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: child, input_public_id: child.conversation_inputs.sole.public_id, acting_user: @human
    ))
    assert_predicate deleted, :accepted?
    AgentRunTask.where(id: call.id).update_all(status: "running", completed_at: nil)
    assert_equal :applied, AgentRuns::Spawn::Run.call(node: call.reload)
    assert_empty child.conversation_inputs, "deleting an accepted brief does not authorize another delivery"

    # The unique index: a run that lost the child's create to a twin reads the winner.
    AgentRunTask.where(id: call.id).update_all(status: "running", completed_at: nil)
    call.reload.stub(:spawned_conversation, nil) do
      assert_equal :applied, AgentRuns::Spawn::Run.call(node: call)
    end
    assert_equal 1, Conversation.where.not(spawn_node_id: nil).count
    assert_empty child.conversation_inputs
  end

  # ── wait: true — the kernel-held await ───────────────────────────────

  test "wait: true parks a tokened await under the continuation: dispatched, off every inbox, never awaiting_human" do
    agent_run = spawning_loop({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)
    await = loop_node(agent_run, "r2t0-spawn-1")

    assert_predicate await, :await?
    assert_equal "dispatched", await.status, "the tokened word: a holder outside the round has the proof"
    assert_not_nil await.resolution_token, "minted for the kernel — `holder: :kernel`"
    refute_predicate await, :asking?, "not a person's question"
    assert_nil await.addressed_executor_id
    assert_nil await.inbox_kind
    assert_equal "absorb", await.on_failure, "expiry is detach + notify: the continuation runs"
    assert_equal AgentRunTasks::AwaitTask::DEFAULT_TIMEOUT_MS, await.await_timeout_ms
    assert_equal PROMPT, await.prompt
    assert_equal await, call_node(agent_run).spawn_await
    assert_equal %w[r2t0 r2t0-spawn-1], sources_of(agent_run, "r2"), "the continuation waits on the await"
    assert_equal "running", agent_run.status
    frontier = Executors::Inbox.call(executor: TaskExecutor.address_for(@agent)).tasks.map { |row| row.fetch(:task_key) }
    refute_includes frontier, "r2t0-spawn-1", "a kernel-held await is nobody's inbox row"
    assert_equal "Spawned conversation #{child.public_id}, answered by @#{@agent.handle}; waiting for its first reply.\n" \
      "Task reference: run_public_id=\"#{agent_run.public_id}\", task=\"r2t0\".",
      tool_result(agent_run, "r2t0")
    assert_equal 1, ConversationInput.where(host: child).count, "the brief was posted after the await existed"
  end

  test "the child's reply settles the await trusted and is the call's paired result" do
    agent_run = spawning_loop({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)
    await = loop_node(agent_run, "r2t0-spawn-1")

    settled = AgentRuns::Parks::Settle.call(node: await, trusted: true, outcome: "completed",
      content: "Three N+1s: user.rb:12, :40, :77.")
    assert_predicate settled, :applied?
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

    results = paired_results(agent_run, "r2")
    assert_equal spawn_envelope("r2t0", "completed", child, "Three N+1s: user.rb:12, :40, :77."), results.fetch("call_0"),
      "the reply IS the call's result, in the spawn envelope naming the child"
    assert_empty request_texts(agent_run, "r2").grep(/Three N\+1s/), "the tip is not rendered twice"
  end

  test "expiry detaches and notifies: timed_out, the spawn sentence, the child untouched" do
    agent_run = spawning_loop({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)
    await = loop_node(agent_run, "r2t0-spawn-1")

    travel_to(await.await_started_at + AgentRunTasks::AwaitTask::DEFAULT_TIMEOUT_MS.fdiv(1000) + 1) do
      assert_predicate AgentRuns::Parks::Settle.call(node: await, timeout: true), :applied?
    end
    assert_equal %w[timed_out await_timeout], [await.reload.status, await.error_key]
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

    assert_equal spawn_envelope("r2t0", "timed_out", child, AgentRuns::TaskResultEnvelope::SPAWN_DETACHED),
      paired_results(agent_run, "r2").fetch("call_0")
    assert_equal 1, ConversationInput.where(host: child).count, "nothing touches the child"
    refute_predicate child.reload, :archived?
  end

  test "the person's cancel of the call cancels the await, not the child" do
    agent_run = spawning_loop({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)

    result = AgentRuns::CancelBranch.call(AgentRuns::CancelBranch::Command.new(
      agent_run: agent_run, acting_user: @human, task_key: "r2t0"
    ))
    assert_predicate result, :accepted?
    assert_equal "canceled", loop_node(agent_run, "r2t0-spawn-1").status
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

    assert_equal spawn_envelope("r2t0", "canceled", child, AgentRuns::TaskResultEnvelope::SPAWN_DETACHED),
      paired_results(agent_run, "r2").fetch("call_0")
    assert_equal 1, ConversationInput.where(host: child).count
  end

  test "two spawns in one message run at once; a spawned child keeps spawn — no depth ceiling" do
    agent_run = spawning_loop({ prompt: "first" }, { prompt: "second", wait: true })

    assert_equal 2, Conversation.where.not(spawn_node_id: nil).count
    assert_equal %w[r2t0 r2t1 r2t1-spawn-1], sources_of(agent_run, "r2")
    child = child_of(agent_run, "r2t0")
    assert_equal @agent, child.declaring_profile
    assert_includes Nexus::ToolDeclarations.names(child.declaring_profile.tool_definitions), "spawn",
      "the child runs under its ANSWERER's whole declaration"
  end
end
