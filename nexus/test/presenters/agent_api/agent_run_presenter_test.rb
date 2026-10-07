require "test_helper"

# The task-grained projection: what a task IS, what it was authored AFTER and what it is still
# WAITING FOR render; the engine's mechanism — join mechanics (those draw on the graph route), the
# continuation mainline, detach intent, the mutation counter — never does.
class AgentAPI::AgentRunPresenterTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper
  include AgentMembershipTestHelper

  GRAPH_WORDS = %i[revision depends_on continue detached join].freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @agent_run = seed(parallel(model("plan"), model("side"), until: 2, key: "done"), ask("gate"))
  end

  test "a waiting task names the tasks it still waits for, and only those" do
    start!(@agent_run)
    run_step!(@agent_run, "plan", sse_success("planned"))

    tasks = projected_tasks
    assert_equal "completed", tasks.fetch("plan")[:status]
    assert_equal "running", tasks.fetch("side")[:status]
    assert_equal ["side"], tasks.fetch("done")[:waiting_on],
      "a settled upstream is no longer waited for"
    assert_equal "waiting", tasks.fetch("done")[:status]
  end

  # `waiting_on` is live and `after` is authored: the first empties as
  # sources settle, the second is the task's static incoming dependencies
  # at every status — both read off the one source list.
  test "a task names what it was authored after, at every status" do
    before = projected_tasks
    assert_equal %w[plan side], before.fetch("done")[:after], "the follower of a fan lists every member"
    assert_equal ["done"], before.fetch("gate")[:after]
    assert_not before.fetch("plan").key?(:after), "a root was authored after nothing"

    start!(@agent_run)
    run_step!(@agent_run, "plan", sse_success("planned"))

    tasks = projected_tasks
    assert_equal %w[plan side], tasks.fetch("done")[:after], "settled sources stay listed"
    assert_equal ["side"], tasks.fetch("done")[:waiting_on]
    assert_equal ["done"], tasks.fetch("gate")[:after]
    assert_equal ["done"], tasks.fetch("gate")[:waiting_on]
  end

  test "a task that has started or settled waits on nothing" do
    start!(@agent_run)
    run_step!(@agent_run, "plan", sse_success("planned"))
    run_step!(@agent_run, "side", sse_success("sided"))

    tasks = projected_tasks
    assert_not tasks.fetch("plan").key?(:waiting_on)
    assert_not tasks.fetch("side").key?(:waiting_on)
    assert_not tasks.fetch("done").key?(:waiting_on), "a settled barrier waits on nothing"
    assert_equal "dispatched", tasks.fetch("gate")[:status]
    assert_not tasks.fetch("gate").key?(:waiting_on), "a park waits on a person, not a task"
  end

  # `queued` is the one rename; every other status — `uncertain` now among
  # them — crosses as itself, and the progress block carries a bucket for
  # it from the vocabulary, so a client's count never silently drops it.
  test "uncertain crosses unrenamed, and the progress block counts it" do
    AgentRunTask.where(id: node("plan").id).update_all(status: "uncertain", error_key: "tool_uncertain")

    assert_equal "uncertain", AgentAPI::AgentRunPresenter.public_status("uncertain")
    full = AgentAPI::AgentRunPresenter.full(@agent_run.reload)
    assert_equal "uncertain", full[:tasks].find { |t| t[:key] == "plan" }[:status]
    assert_equal 1, full[:task_progress].fetch(:uncertain)
    assert_equal 0, full[:task_progress].fetch(:timed_out)
  end

  test "the trace, the listing and the single-task read carry no engine word" do
    full = AgentAPI::AgentRunPresenter.full(@agent_run)
    basic = AgentAPI::AgentRunPresenter.basic(@agent_run)
    detail = AgentAPI::AgentRunPresenter.task_detail(node("done"))

    GRAPH_WORDS.each do |word|
      assert_not full.key?(word), "#{word} on the trace"
      assert_not basic.key?(word), "#{word} on the listing"
      assert_not detail.key?(word), "#{word} on the task read"
      full[:tasks].each { |task| assert_not task.key?(word), "#{word} on task #{task[:key]}" }
    end
    assert_equal %w[plan side], full[:tasks].find { |t| t[:key] == "done" }[:waiting_on]
  end

  # THE SETTLED CALL'S PREVIEW ON ITS READ: the bounded preview the settled-call frame carries rides
  # the single-task read too, so a reader that attached after the call settled renders what a live
  # follower rendered; absent where no output was stamped.
  test "the task read carries the preview the settled call's frame carries" do
    done = node("done")
    done.update_columns(output_preview: "a.rb\nb.rb")
    assert_equal "a.rb\nb.rb", AgentAPI::AgentRunPresenter.task_detail(done.reload).fetch(:output_preview)
    assert_not AgentAPI::AgentRunPresenter.task_detail(node("gate")).key?(:output_preview)
  end

  # A ROUND'S REQUEST BYTES ON ITS READ: the size a round's request was sealed with is a stored fact
  # of the body, served on the single-task read of a model task — absent on every other kind, and on
  # the trace row, which is a task list.
  test "a round's task read carries the bytes its request was sealed with" do
    start!(@agent_run)
    plan = node("plan")
    sealed = plan.selected_model_invocation.content_bodies.find_by!(role: "request")

    detail = AgentAPI::AgentRunPresenter.task_detail(plan)
    assert_equal sealed.byte_size, detail.fetch(:request_bytes)
    assert_equal sealed.effective_text.bytesize, detail.fetch(:request_bytes), "the stored fact IS the text's size"
    assert_operator detail.fetch(:request_bytes), :>, 0
    assert_not AgentAPI::AgentRunPresenter.task(plan).key?(:request_bytes), "the trace row is a task list"
    assert_not AgentAPI::AgentRunPresenter.task_detail(node("gate")).key?(:request_bytes), "an await seals no request"
    assert_not AgentAPI::AgentRunPresenter.task_detail(node("done")).key?(:request_bytes), "nor a join"
  end

  # A ROUND'S `instructions` ON ITS READ: the system field a `raw` step was authored with is stored
  # on the round (`system_instructions`) and served on the single-task read beside `prompt` — what
  # the SDK wrote, read back; absent on a round authored without one, and on the trace row, which is
  # a task list.
  test "a round's task read carries the instructions it was authored with" do
    briefed = seed(model("brief", "instructions" => "Be brief."), model("plain"))

    assert_equal "Be brief.", AgentAPI::AgentRunPresenter.task_detail(node("brief", briefed)).fetch(:instructions)
    assert_not AgentAPI::AgentRunPresenter.task(node("brief", briefed)).key?(:instructions), "the trace row is a task list"
    assert_not AgentAPI::AgentRunPresenter.task_detail(node("plain", briefed)).key?(:instructions),
      "a round authored without one reads none"
  end

  # THE UI'S TWO FIELDS ON THE TASK READ: `title` and `metadata` an executor sent at commit are
  # stored on the row and served on the single-task read alone, only when present — the trace row is
  # a task list, and a result that sent neither reads neither key.
  test "a task read carries the title and metadata its result was committed with" do
    asked = seed(ask("gate"))
    start!(asked)
    gate = node("gate", asked)
    settled = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, content: "the answer",
      title: "gate answered", metadata: { "checkpoint" => { "step" => 3 } }
    )
    assert_predicate settled, :applied?

    detail = AgentAPI::AgentRunPresenter.task_detail(gate.reload)
    assert_equal "gate answered", detail.fetch(:title)
    assert_equal({ "checkpoint" => { "step" => 3 } }, detail.fetch(:metadata))
    assert_equal "the answer", detail.fetch(:output), "the model's channel is untouched"
    row = AgentAPI::AgentRunPresenter.task(gate)
    assert_not row.key?(:title), "the trace row is a task list"
    assert_not row.key?(:metadata)

    plain = AgentAPI::AgentRunPresenter.task_detail(node("plan"))
    assert_not plain.key?(:title), "a result that sent none reads none"
    assert_not plain.key?(:metadata)
  end

  # The turn shape beside the loop's row: a standalone loop renders the function over its own rows,
  # and its own waiting room.
  test "a standalone loop renders its turn shape and its input queue" do
    full = AgentAPI::AgentRunPresenter.full(@agent_run)
    assert_equal({ status: "pending" }, full[:turn])
    assert_equal({ limit: AgentRun::INPUT_QUEUE_LIMIT, held: 0 }, full[:input_queue])
    assert_equal({ status: "pending" }, AgentAPI::AgentRunPresenter.basic(@agent_run)[:turn])

    @agent_run.update!(status: "needs_attention", attention_reason: "halt_failure")
    loop_input!(@agent_run, acting_user: @human, text: "held")
    full = AgentAPI::AgentRunPresenter.full(@agent_run.reload)
    assert_equal({ status: "failed", failure_reason_key: "halt_failure" }, full[:turn])
    assert_equal 1, full.dig(:input_queue, :held)
  end

  # A loop-backed loop renders the TURN row's status through the seam —
  # the conversation plane's truth — and the reason only while the seam's
  # variant is still the active one.
  test "a loop-backed loop renders its turn row, and drops the reason once a person overrode it" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    seam.agent_run.update!(status: "needs_attention", attention_reason: "halt_failure")

    turn = AgentAPI::AgentRunPresenter.full(seam.agent_run)[:turn]
    assert_equal({ status: "running", failure_reason_key: "halt_failure",
                   public_id: seam.turn.public_id,
                   answering_user_public_id: @human.public_id,
                   conversation_public_id: conversation.public_id }, turn)
    assert_not AgentAPI::AgentRunPresenter.full(seam.agent_run).key?(:input_queue),
      "a loop-backed loop's waiting room is its conversation's"

    override = ConversationTurnVariant.create!(
      account: @account, conversation_turn: seam.turn, position: 1,
      status: "completed", source: "edit"
    )
    seam.turn.update!(active_variant: override, status: "completed")
    turn = AgentAPI::AgentRunPresenter.basic(seam.agent_run.reload)[:turn]
    assert_equal({ status: "completed", public_id: seam.turn.public_id,
                   answering_user_public_id: @human.public_id,
                   conversation_public_id: conversation.public_id }, turn)
  end

  # THE STATED PLACE: the turn block carries the model the loop-backed turn runs on — the seam
  # variant's frozen selection, in the loop's own model shape — on `full` and
  # `basic` alike, so a follower reads the model in use here.
  test "a loop-backed loop's turn block names the model the turn runs on, in the loop's model shape" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    # The selection columns are frozen at the variant's birth (attr_readonly).
    ConversationTurnVariant.where(id: seam.variant.id)
      .update_all(provider_id: "dev", model_ref: "mock-text", reasoning_effort: "low", reasoning_enabled: false)

    %i[full basic].each do |shape|
      turn = AgentAPI::AgentRunPresenter.public_send(shape, seam.agent_run.reload)[:turn]
      assert_equal({ status: "running", public_id: seam.turn.public_id,
                     answering_user_public_id: @human.public_id,
                     conversation_public_id: conversation.public_id,
                     model: { model: "dev/mock-text", reasoning_effort: "low", reasoning_enabled: false } }, turn, shape.to_s)
    end
  end

  test "a group turn exposes its explicit answerer rather than the conversation default" do
    default = users(:agent)
    peer = create_agent_member(display_name: "Scheduled reviewer", agent_identifier: "scheduled-reviewer")
    declare_tools!(peer)
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: default)
    turn, loop = materialize_loop_reply!(conversation, agent: @human, text: "Schedule this review.",
      answering_user_public_id: peer.public_id)

    assert_equal default, conversation.reload.answering_user
    assert_equal peer, turn.answering_user
    %i[full basic].each do |shape|
      rendered = AgentAPI::AgentRunPresenter.public_send(shape, loop.reload).fetch(:turn)
      assert_equal peer.public_id, rendered.fetch(:answering_user_public_id), shape.to_s
      assert_equal conversation.public_id, rendered.fetch(:conversation_public_id), shape.to_s
    end
    listed = AgentAPI::AgentRunPresenter.basic_many([loop]).sole.fetch(:turn)
    assert_equal peer.public_id, listed.fetch(:answering_user_public_id)
  end

  # PRESENCE on the addressee (r-modes M4): who a started call is for and
  # whether that executor's socket is live, read off the row the trace
  # already preloads; the claimant stays a public-id snapshot. The inbox row
  # is the addressee reading itself and carries neither (its own test pins
  # the exact shape).
  test "a task's addressee carries its presence and contact sample; the claimant does not" do
    NexusServer.register
    agent_run = seed(tool("call"))
    node = agent_run.agent_run_tasks.find_by!(node_key: "call")
    node.update_columns(addressed_role: "runner", addressed_executor_id: suite_runner.id,
      claimed_by_executor_public_id: suite_runner.public_id)
    suite_runner.update!(last_seen_at: 2.minutes.ago)
    suite_runner.mark_connected("socket-1")

    task = AgentAPI::AgentRunPresenter.full(agent_run.reload).fetch(:tasks).sole
    assert_equal(
      { role: "runner", executor_public_id: suite_runner.public_id,
        presence: "online", last_seen_at: suite_runner.reload.last_seen_at },
      task.fetch(:addressed_to)
    )
    assert_equal({ executor_public_id: suite_runner.public_id }, task.fetch(:claimed_by))

    suite_runner.clear_connected("socket-1")
    assert_equal "offline", AgentAPI::AgentRunPresenter.task_detail(node.reload).dig(:addressed_to, :presence)
  end

  # THE BINDING IS READABLE: `runner` on the full document, nil before any binding and after a reap
  # (nullify FK); never on the listing.
  test "the loop document carries its runner binding with presence, nil when unbound or reaped" do
    NexusServer.register
    agent_run = seed(model("plan"))
    assert_equal suite_runner, agent_run.default_runner, "the runner the seed named, bound at create"
    suite_runner.update!(last_seen_at: 1.minute.ago)
    suite_runner.mark_connected("socket-2")

    assert_equal(
      { executor_public_id: suite_runner.public_id, display_name: suite_runner.display_name,
        presence: "online", last_seen_at: suite_runner.reload.last_seen_at },
      AgentAPI::AgentRunPresenter.full(agent_run.reload).fetch(:default_runner)
    )
    assert_not AgentAPI::AgentRunPresenter.basic(agent_run).key?(:runner)

    agent_run.update_columns(default_runner_executor_id: nil)
    assert_nil AgentAPI::AgentRunPresenter.full(agent_run.reload)[:default_runner]
  end

  private

    def start!(agent_run)
      AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      ))
      clear_enqueued_jobs
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      clear_enqueued_jobs
    end

    # Admission admits everything queued at once, so the attempts are kept
    # across calls and answered per node.
    def run_step!(agent_run, key, behaviour)
      @admitted ||= {}
      ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
        @admitted[candidate.attempt.model_invocation_id] = candidate.attempt
      end
      clear_enqueued_jobs
      apply_via(@admitted.fetch(node(key).selected_model_invocation_id), behaviour)
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      clear_enqueued_jobs
    end

    def node(key, agent_run = @agent_run) = agent_run.agent_run_tasks.find_by!(node_key: key)

    def projected_tasks
      AgentAPI::AgentRunPresenter.full(@agent_run.reload).fetch(:tasks).index_by { |t| t[:key] }
    end
end
