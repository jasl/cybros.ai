require "test_helper"

# THE ONE WAY A MODEL CAN ASK A HUMAN ANYTHING, and until this round it
# did not work.
#
# `g.ask` is documented on the compose tool as "wait for a human", and it
# built the await it promised. But an await's resolution token is a
# BEARER second factor returned only in the append's receipt, and a
# receipt is persisted only when the command carries an idempotency key —
# which a KERNEL command, the kind a model's own composition rides, never
# does. So the token was minted into a column, handed to nobody, and
# `Settle` refused `stale_claim` to every caller who tried to answer.
#
# A model could ask, and the ask was answerable only by its own timeout.
class AgentLoops::ComposedAskTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper
  include LoopSeamTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def model(key, **over) = super(key, "tools" => [Nexus::Compose::DEFINITION, Nexus::Tools::ASK], **over)

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def step_attempt(agent_loop, key)
    invocation_id = node(agent_loop, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  # `wait: true`: these cases pin the continuation reading the answer, the attached shape (the
  # default is detached).
  def compose_round!(agent_loop, script, key: "round1")
    apply_via(step_attempt(agent_loop, key), sse_success("composing", tool_calls: [
      { id: "call_c", name: "compose", arguments: { script: script, params: {}, wait: true }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentLoops::ComposeJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    agent_loop.reload
  end

  # The flat tool: one question, one field, no script.
  def ask_round!(agent_loop, arguments, key: "round1")
    apply_via(step_attempt(agent_loop, key), sse_success("asking", tool_calls: [
      { id: "call_a", name: "ask", arguments: arguments.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentLoops::AskJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    agent_loop.reload
  end

  def asking_loop(flat: false)
    agent_loop = seed(model("round1"))
    start!(agent_loop)
    if flat
      ask_round!(agent_loop, { prompt: "Which database should I use?" })
    else
      compose_round!(agent_loop, 'g.ask({ prompt: "Which database should I use?" });')
    end
    agent_loop
  end

  def tool_result(agent_loop, key) = node(agent_loop, key).content_bodies.find_by(role: "output")&.effective_text

  def request_texts(agent_loop, key)
    ModelInvocation.find(node(agent_loop, key).selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.filter_map { |e| e.content_fragment.payload.dig("parts", 0, "text") }
  end

  def continue!(agent_loop)
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  def composed_await(agent_loop)
    agent_loop.agent_loop_nodes
      .where(type: AgentLoopNodes::AwaitTask.sti_name).sole
  end

  # THE FLAT TOOL: `ask({prompt})` places one await under the round's continuation through the door
  # compose uses — tokenless, halt on expiry, announced — and the answer reaches the model as
  # `<answer task=…>`.
  test "ask({prompt}) parks one question the continuation waits on, and the answer is delivered as <answer>" do
    agent_loop = asking_loop(flat: true)

    await = node(agent_loop, "r1t0-ask-1")
    assert_equal "awaiting_input", await.status
    assert_nil await.resolution_token, "a model's question answers to write standing"
    assert_equal "halt", await.on_failure, "an expired question holds for a human"
    assert_equal AgentLoopNodes::AwaitTask::MAX_HOLD_MS, await.await_timeout_ms
    assert_equal "Which database should I use?", await.content_bodies.find_by(role: "input").effective_text
    assert_equal 'Asked. The answer is in your next message as <answer task="r1t0">.',
      tool_result(agent_loop, "r1t0")
    assert_equal %w[r1t0 r1t0-ask-1], node(agent_loop, "r1").sources.map(&:node_key).sort,
      "this turn waits"
    assert_equal %w[round1 r1t0 r1t0-ask-1], node(agent_loop, "r1").input_from_node_keys

    AgentLoops::EvaluateQuiescence.call(agent_loop.reload)
    assert_equal AgentLoops::EvaluateQuiescence::ASKING_REASON, agent_loop.reload.attention_reason
    item = agent_loop.conversation_event_items.where(item_type: "attention_required").order(:sequence).last
    assert_equal ["r1t0-ask-1"], item.payload.fetch("blocked_task_keys")

    assert_predicate AgentLoops::Parks::Settle.call(node: await, content: "Postgres"), :applied?
    continue!(agent_loop)
    assert_equal ['<answer task="r1t0">Postgres</answer>'], request_texts(agent_loop, "r1").last(1),
      "the answer names the CALL, as a message that is not the person typing anew"
  end

  # ONE field name on every surface: the repair names the fields.
  test "ask refuses question: by naming prompt, and an empty prompt by sentence" do
    agent_loop = seed(model("round1"), model("again"))
    start!(agent_loop)
    ask_round!(agent_loop, { question: "Which database?" })
    assert_equal "question is not a parameter; the fields are prompt, options and multi.", tool_result(agent_loop, "r1t0")
    assert node(agent_loop, "r1t0").output_summary["is_error"]
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "r1t0-ask-1")

    continue!(agent_loop)
    ask_round!(agent_loop, { prompt: "" }, key: "r1")
    assert_equal AgentLoops::Asks::Run::EMPTY_PROMPT, tool_result(agent_loop, "r2t0")
  end

  # THE CHOICES AS DATA (audit refs-parity-6): `options`/`multi` ride the
  # flat call and a composed `g.ask`, land on the await row, and are served
  # to the person on the inbox row and the task detail; the answer reaches
  # the model as `<answer>` exactly as before — the person's text is the
  # choice, and none of the three references echoes the option list.
  test "ask({prompt, options, multi}) stores the choices on the await row and serves them to the person" do
    agent_loop = seed(model("round1"))
    start!(agent_loop)
    ask_round!(agent_loop, { prompt: "Which database?", options: %w[Postgres MySQL], multi: false })

    await = node(agent_loop, "r1t0-ask-1")
    assert_equal "awaiting_input", await.status
    assert_equal %w[Postgres MySQL], await.ask_options
    assert_equal false, await.ask_multi
    detail = AgentAPI::AgentLoopPresenter.task_detail(await)
    assert_equal ["Which database?", %w[Postgres MySQL], false], detail.values_at(:prompt, :options, :multi)
    row = Executors::Inbox.row(await)
    assert_equal [%w[Postgres MySQL], false], row.values_at(:options, :multi)

    assert_predicate AgentLoops::Parks::Settle.call(node: await, content: "MySQL"), :applied?
    continue!(agent_loop)
    assert_equal ['<answer task="r1t0">MySQL</answer>'], request_texts(agent_loop, "r1").last(1),
      "the answer is the choice; the envelope's bytes are what they were"

    composed = seed(model("round1"))
    start!(composed)
    compose_round!(composed, 'g.ask({ prompt: "Which?", options: ["a", "b"], multi: true });')
    assert_equal [%w[a b], true], composed_await(composed).values_at(:ask_options, :ask_multi)

    plain = seed(model("round1"))
    start!(plain)
    ask_round!(plain, { prompt: "Proceed?" })
    assert_nil node(plain, "r1t0-ask-1").ask_options, "an ask with no choices stores none"
    refute AgentAPI::AgentLoopPresenter.task_detail(node(plain, "r1t0-ask-1")).key?(:options), "and serves none"
  end

  # The choices' own refusals, by sentence, before any await is placed.
  test "ask refuses options that are not strings and a multi that is not a boolean" do
    agent_loop = seed(model("round1"), model("again"))
    start!(agent_loop)
    ask_round!(agent_loop, { prompt: "Which?", options: [1, 2] })
    assert_equal AgentLoops::Asks::Run::OPTIONS_INVALID, tool_result(agent_loop, "r1t0")
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "r1t0-ask-1")

    continue!(agent_loop)
    ask_round!(agent_loop, { prompt: "Which?", options: %w[a], multi: "yes" }, key: "r1")
    assert_equal AgentLoops::Asks::Run::MULTI_INVALID, tool_result(agent_loop, "r2t0")
  end

  test "a composed g.ask answers under its own key" do
    agent_loop = asking_loop
    AgentLoops::Parks::Settle.call(node: composed_await(agent_loop), content: "Postgres")
    continue!(agent_loop)

    assert_equal ['<answer task="r1t0-ask-1">Postgres</answer>'], request_texts(agent_loop, "r1").last(1)
  end

  test "a model's ask mints no token, because there is nobody to hand one to" do
    await = composed_await(asking_loop)

    assert_equal "awaiting_input", await.status, "the ask should be parked and waiting"
    assert_nil await.resolution_token,
      "a token nobody can receive is a secret in a column, not a second factor"
    assert_predicate await, :answers_to_write_standing?
  end

  test "a model's ask is answerable" do
    agent_loop = asking_loop
    await = composed_await(agent_loop)

    # NO TOKEN IS PRESENTED, because none exists. What authorizes this is
    # the resolution door's own check — write standing on the workspace —
    # which is the same standing that could have authored the await by
    # hand.
    settled = AgentLoops::Parks::Settle.call(node: await, content: "Postgres")
    assert_predicate settled, :applied?

    await.reload
    assert_equal "completed", await.status
    assert_equal "Postgres", await.content_bodies.find_by(role: "output").effective_text
  end

  # The regression this whole file exists for.
  test "before this, a model's ask was refused to every caller" do
    agent_loop = asking_loop
    await = composed_await(agent_loop)
    # `resolution_token` is attr_readonly, so the old state is restored
    # the only way it can be: underneath the model.
    AgentLoopNode.where(id: await.id).update_all(resolution_token: SecureRandom.uuid)

    # This is exactly the state the kernel used to leave behind: a token
    # in the column that no receipt ever carried out. Every answer is
    # refused, and only the timeout sweep can end it.
    refused = AgentLoops::Parks::Settle.call(node: await.reload, content: "Postgres")
    assert_equal :stale_claim, refused.outcome
  end

  # THE ASK MUST BE HEARD. A parked await is a RUNNING node, so a loop
  # holding a model's question is not quiescent and looks — to every
  # surface that reads status — exactly like a loop busy doing the work.
  # That is what it looked like the first time a live model asked one.
  test "a model's ask announces itself, and names the task to answer" do
    agent_loop = asking_loop
    await = composed_await(agent_loop)

    assert_equal "running", agent_loop.reload.status,
      "other branches may still be working; the loop is not held"
    assert_equal AgentLoops::EvaluateQuiescence::ASKING_REASON,
      agent_loop.attention_reason

    item = agent_loop.conversation_event_items
      .where(item_type: "attention_required").order(:sequence).last
    assert_not_nil item, "nothing narrated the ask, so nobody could hear it"
    assert_equal AgentLoops::EvaluateQuiescence::ASKING_REASON,
      item.payload.fetch("reason")
    # It names the QUESTION, not the pending-failure set — an adjudicator
    # handed an empty list has been told to act on nothing.
    assert_equal [await.node_key], item.payload.fetch("blocked_task_keys")
  end

  test "answering the ask clears the announcement" do
    agent_loop = asking_loop
    AgentLoops::Parks::Settle.call(node: composed_await(agent_loop), content: "Postgres")
    AgentLoops::EvaluateQuiescence.call(agent_loop.reload)

    assert_nil agent_loop.reload.attention_reason,
      "a stale ask is what a console renders as something a human must do"
  end

  # ── THE APPROVAL ARM, in the ask arm's mould ──────── A round that asks a question AND calls a
  # tool. Under `ask` the model's `ask` call is itself a tool row; an allow rule for the kernel
  # tools lets it run while the read parks. The read parks in the scheduling pass and the hold is
  # announced there, before the ask job has parked the question — and a stamp already standing is
  # never replaced (the never-overwrite rule), so the question does not take the word from the hold;
  # the announcement names the held key, and clears when the row leaves.
  test "a held approval announces approval_required naming the held key, a later question never overwrites it, and it clears when the row leaves" do
    agent_loop = seed(model("round1", "tools" => [Nexus::Tools::ASK, READ_TOOL]), approval_mode: "ask",
      approval_rules: [{ "tool" => "memory_*|ask|task|compose", "verdict" => "allow" }])
    start!(agent_loop)
    apply_via(step_attempt(agent_loop, "round1"), sse_success("both", tool_calls: [
      { id: "call_a", name: "ask", arguments: { prompt: "which?" }.to_json },
      { id: "call_r", name: "read_file", arguments: "{}" },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentLoops::AskJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    await = composed_await(agent_loop)
    call = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_r")
    assert_equal "awaiting_input", await.status
    assert_equal "needs_approval", call.status, "the read parks; the ask ran by rule"
    assert_equal "rule", agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_a").approval_origin

    assert_equal AgentLoops::EvaluateQuiescence::APPROVAL_REASON, agent_loop.reload.attention_reason,
      "the hold was announced in the scheduling pass; the later question never overwrites a standing word"
    AgentLoops::EvaluateQuiescence.call(agent_loop.reload)
    assert_equal AgentLoops::EvaluateQuiescence::APPROVAL_REASON, agent_loop.reload.attention_reason
    assert_equal "running", agent_loop.status
    item = agent_loop.conversation_event_items.where(item_type: "attention_required").order(:sequence).last
    assert_equal AgentLoops::EvaluateQuiescence::APPROVAL_REASON, item.payload.fetch("reason")
    assert_equal [call.node_key], item.payload.fetch("blocked_task_keys"), "it names the held call, not the question"

    assert_predicate AgentLoops::Parks::Settle.call(node: await, content: "Postgres"), :applied?
    AgentLoops::EvaluateQuiescence.call(agent_loop.reload)
    assert_equal AgentLoops::EvaluateQuiescence::APPROVAL_REASON, agent_loop.reload.attention_reason,
      "the answered question changes nothing: the hold still stands"

    # The row leaves by the park clock here (the verbs have their own
    # suites): the sweep reads the database clock, so the clock is
    # back-dated rather than travelled.
    AgentLoopNode.where(id: call.id).update_all(await_started_at: (AgentLoopNodes::AwaitTask::MAX_HOLD + 1.second).ago)
    assert_equal 1, AgentLoops::Parks::TimeoutSweep.call[:expired]
    assert_equal %w[timed_out approval_expired], call.reload.values_at(:status, :error_key)
    assert_nil agent_loop.reload.attention_reason, "the announcement clears with the row"
  end

  # A background held row (a detached branch's call under `ask`) announces
  # — a console lists it — but does not keep the reply from being final:
  # the loop-backed turn delivers around it and stays `running` with the
  # word standing until the row leaves.
  test "a background held row announces but does not keep the reply from being final" do
    agent = users(:agent)
    announce_tools!(agent, %w[read_file])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent)
    seam = create_loop_backed_turn(conversation: conversation, acting_user: agent, approval_mode: "ask")
    agent_loop = seam.agent_loop
    seeded = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
      agent_loop: agent_loop, origin: "kernel", tip: AgentLoops::Tasks::Tip.seed("round"),
      steps: [AgentLoops::Tasks::Step::Model.new(key: "r1", model: MOCK_MODEL, prompt: "p")]
    ))
    assert_predicate seeded, :applied?
    # Stamped, not transitioned: only the settlement matters here.
    AgentLoopNode.where(agent_loop_id: agent_loop.id, node_key: "r1")
      .update_all(status: "completed", started_at: Time.current, completed_at: Time.current)
    branched = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
      agent_loop: agent_loop, origin: "model", tip: AgentLoops::Tasks::Tip.seed("branch"),
      steps: [AgentLoops::Tasks::Step::Tool.new(key: "bg", name: "read_file", detached: true)]
    ))
    assert_predicate branched, :applied?

    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs

    bg = node(agent_loop, "bg")
    assert_equal "needs_approval", bg.status
    assert_predicate bg, :detached?
    agent_loop.reload
    assert_not_nil agent_loop.delivered_at, "the reply is final around the background hold"
    assert_equal "running", agent_loop.status, "the loop stays its own until the background row settles"
    assert_equal AgentLoops::EvaluateQuiescence::APPROVAL_REASON, agent_loop.attention_reason,
      "the hold's word stands across the delivery"

    AgentLoops::EvaluateQuiescence.call(agent_loop.reload)
    assert_equal AgentLoops::EvaluateQuiescence::APPROVAL_REASON, agent_loop.reload.attention_reason,
      "level-triggered: a later pass keeps it"
  end

  # An await a CLIENT authored was handed its token in a receipt, so
  # somebody already knows it is waiting and arranged to answer it.
  # Announcing it would nag an operator about a rendezvous they set up.
  test "an authored await does not announce" do
    agent_loop = seed(ask("gate"))
    AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    AgentLoops::EvaluateQuiescence.call(agent_loop.reload)

    assert_equal "dispatched", node(agent_loop, "gate").status
    assert_nil agent_loop.reload.attention_reason
  end

  # THE HALF THAT MUST NOT WIDEN. `Settle` is one engine behind two doors,
  # and a tool task's claim token is absent BEFORE a runner claims it —
  # so a predicate written on "no token" rather than on the class would
  # let any writer settle work a runner is in the middle of, stealing the
  # result out from under it.
  test "an unclaimed tool task is still refused to a caller with no token" do
    agent_loop = seed(
      tool("t", "write"),
    )
    AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)

    tool = node(agent_loop.reload, "t")
    assert_equal "dispatched", tool.status
    assert_nil tool.settlement_claim_token, "nothing has claimed it yet"

    refused = AgentLoops::Parks::Settle.call(node: tool, content: "not mine to give")
    assert_equal :stale_claim, refused.outcome
  end

  # An AUTHORED await keeps its second factor: the client that appended it
  # got the token in a receipt, so presenting it is possible and required.
  test "an authored await still demands the token it was issued" do
    agent_loop = seed(ask("gate"))
    AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)

    gate = node(agent_loop.reload, "gate")
    assert_not_nil gate.resolution_token, "an authored await is issued a token"

    refused = AgentLoops::Parks::Settle.call(node: gate, content: "no token presented")
    assert_equal :stale_claim, refused.outcome

    settled = AgentLoops::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, content: "with the token"
    )
    assert_predicate settled, :applied?
  end
end
