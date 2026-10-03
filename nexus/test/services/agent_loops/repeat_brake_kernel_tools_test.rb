require "test_helper"

# THE REPEAT BRAKE over the kernel's own verbs. A waited `task` and a `wait` are judged by the tip the
# reader held — the branch's last word, the observing await — never by the launch receipt; a
# background launch (`task`, `compose`, `spawn`, `send`) is identified as a launch, since the receipt's
# only varying bytes are the kernel's own key; delivered material is judged by where it came from and
# what it said. And a branch is a chain like the spine: its refusal fails the branch's round, which
# its consumer reads, and the spine runs on.
class AgentLoops::RepeatBrakeKernelToolsTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def window = AgentLoops::RepeatBrake::NOVELTY_WINDOW

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    clear_enqueued_jobs
    schedule_loop!(agent_loop)
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def attempt_for(agent_loop, key)
    invocation_id = node(agent_loop, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def answer!(agent_loop, key, text)
    apply_via(attempt_for(agent_loop, key), sse_success(text))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule_loop!(agent_loop)
  end

  # The model at `key` makes `tool_calls`, the fan expands and the kernel's jobs run. Answers the
  # continuation's key.
  def kernel_round!(agent_loop, key, tool_calls, jobs)
    apply_via(attempt_for(agent_loop, key), sse_success("working", tool_calls: tool_calls))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    asked = node(agent_loop, key)
    refute_equal "failed", asked.status, "#{key} was refused: #{asked.error_key} #{asked.error_detail}"
    perform_enqueued_jobs(only: [*jobs, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    clear_enqueued_jobs
    continuation_of(agent_loop, key).node_key
  end

  def continuation_of(agent_loop, key)
    agent_loop.agent_loop_nodes.where("? = ANY(input_from_node_keys)", key)
      .find_by!(expansion_parent_id: node(agent_loop, key).id, type: AgentLoopNodes::ModelTask.sti_name)
  end

  def refused!(agent_loop, key, tool_calls)
    apply_via(attempt_for(agent_loop, key), sse_success("working", tool_calls: tool_calls))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    stalled = node(agent_loop, key)
    assert_equal %w[failed round_expansion_refused], [stalled.status, stalled.error_key], "#{key} was not refused"
    assert_equal AgentLoops::RepeatBrake::REPEAT_LOOP, stalled.error_detail
    stalled
  end

  def refusals(agent_loop) = agent_loop.agent_loop_nodes.where(error_key: AgentLoops::ExpandRound::EXPANSION_REFUSED)

  def call(name, **arguments) = { id: "call_#{name}", name: name, arguments: arguments.to_json }

  def read(path) = { id: "call_read", name: "read_file", arguments: { path: path }.to_json }

  # ── a waited task ────────────────────────────────────────────────────

  # One spine round asking the same waited `task`; its branch answers `text`, and the continuation
  # reads that answer as the call's paired result. Answers the continuation's key.
  def waited_task_round!(agent_loop, key, text)
    continuation = kernel_round!(agent_loop, key, [call("task", prompt: "Is the build ready?", wait: true)],
      [AgentLoops::TaskToolJob])
    answer!(agent_loop, AgentLoops::TaskTool::Run.root_key("#{continuation}t0"), text)
    assert_equal "running", node(agent_loop, continuation).status, "the continuation read the branch's answer"
    continuation
  end

  test "a waited task is judged by its branch's answer: the same answer repeats, a changing one is new" do
    unchanged = seed(model("ask", "tools" => [READ_TOOL, Nexus::Tools::TASK]))
    start!(unchanged)
    key = "ask"
    (window + 1).times { key = waited_task_round!(unchanged, key, "NOT READY") }
    refused!(unchanged, key, [call("task", prompt: "Is the build ready?", wait: true)])

    changing = seed(model("ask", "tools" => [READ_TOOL, Nexus::Tools::TASK]))
    start!(changing)
    key = "ask"
    ((2 * window) + 2).times { |n| key = waited_task_round!(changing, key, "item-#{n}") }
    assert_empty refusals(changing)
  end

  # ── wait ─────────────────────────────────────────────────────────────

  # One spine round waiting on `target` for a second: the await observes work already done at once,
  # else times out; the continuation reads the await as the call's result.
  def wait_round!(agent_loop, key, target)
    continuation = kernel_round!(agent_loop, key, [call("wait", task: target, timeout_ms: 1_000)],
      [AgentLoops::WaitToolJob])
    await = node(agent_loop, "#{continuation}t0#{AgentLoops::WaitTool::Run::SUFFIX}")
    # The scheduler reconciles a dispatched await against its target; one still working times out.
    schedule_loop!(agent_loop)
    unless await.reload.terminal?
      travel(2.seconds) { DatabaseClock.stub(:now, Time.current) { AgentLoops::Parks::TimeoutSweep.call } }
    end
    schedule_loop!(agent_loop)
    assert_equal "running", node(agent_loop, continuation).status, "the continuation read the await"
    continuation
  end

  def launch!(agent_loop, key, *prompts)
    kernel_round!(agent_loop, key, prompts.each_with_index.map { |prompt, index|
      { id: "call_#{index}", name: "task", arguments: { prompt: prompt }.to_json }
    }, [AgentLoops::TaskToolJob])
  end

  test "a wait is judged by its await: new while completions arrive, a repeat on work that hangs" do
    tools = [READ_TOOL, Nexus::Tools::TASK, Nexus::Tools::WAIT]
    rotating = seed(model("ask", "tools" => tools))
    start!(rotating)
    launched = launch!(rotating, "ask", "build one", "build two", "build three")
    targets = (0..2).map { |index| "#{launched}t#{index}" }
    # Each target answers a few rounds before the wait that finds it done.
    finishes = { 6 => targets[0], 10 => targets[1], 14 => targets[2] }

    key = launched
    ((2 * window) + 2).times do |n|
      answer!(rotating, AgentLoops::TaskTool::Run.root_key(finishes[n]), "#{finishes[n]} done") if finishes[n]
      key = wait_round!(rotating, key, targets[n % 3])
    end
    assert_empty refusals(rotating), "a rotation of waits is new while completions arrive"

    hung = seed(model("ask", "tools" => tools))
    start!(hung)
    launched = launch!(hung, "ask", "build forever")
    key = launched
    (window + 1).times do
      key = wait_round!(hung, key, "#{launched}t0")
      await = node(hung, "#{key}t0#{AgentLoops::WaitTool::Run::SUFFIX}")
      assert_equal %w[timed_out await_timeout], [await.status, await.error_key]
    end
    refused!(hung, key, [call("wait", task: "#{launched}t0", timeout_ms: 1_000)])
  end

  # ── a waited compose ─────────────────────────────────────────────────

  SCRIPT = 'g.tool({ name: "read_file", input: { path: "status.txt" } });'.freeze

  # One spine round composing the same one-tool graph and waiting on it; the tool answers `text`,
  # delivered to the continuation as the stage's result.
  def compose_round!(agent_loop, key, text)
    continuation = kernel_round!(agent_loop, key, [call("compose", script: SCRIPT, params: {}, wait: true)],
      [AgentLoops::ComposeJob])
    stage = agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ToolTask.sti_name, status: "dispatched").sole
    assert_predicate AgentLoops::Parks::Settle.call(node: stage, trusted: true, content: text, outcome: "completed"),
      :applied?
    schedule_loop!(agent_loop)
    assert_equal "running", node(agent_loop, continuation).status, "the continuation read the stage's result"
    continuation
  end

  test "a waited compose whose script and results repeat is a repeat" do
    agent_loop = seed(model("ask", "tools" => [READ_TOOL, Nexus::Compose::DEFINITION]))
    start!(agent_loop)

    key = "ask"
    (window + 1).times { key = compose_round!(agent_loop, key, "NOT READY") }
    refused!(agent_loop, key, [call("compose", script: SCRIPT, params: {}, wait: true)])
  end

  # ── send ─────────────────────────────────────────────────────────────

  # A `send` to one's own child returns a receipt naming the call's key: the kernel's own byte,
  # never novelty. The same message to the same child, round after round, is a repeat.
  test "a send to one's own child repeated is a repeat" do
    declare_tools!(@agent, tools: [Nexus::Tools::SPAWN, Nexus::Tools::SEND, READ_TOOL])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    post_input!(conversation, acting_user: @human, text: "go")
    _turn, agent_loop = materialize_loop_reply!(conversation, agent: @agent, text: nil)
    schedule_loop!(agent_loop)

    key = kernel_round!(agent_loop, "r1", [call("spawn", prompt: "Review the diff.", label: "reviewer")],
      [AgentLoops::ConversationToolJob])
    (window + 1).times do
      key = kernel_round!(agent_loop, key, [call("send", to: "reviewer", message: "ping")],
        [AgentLoops::ConversationToolJob])
      assert_match(/\ASent to /, node(agent_loop, "#{key}t0").output_body.effective_text)
    end
    refused!(agent_loop, key, [call("send", to: "reviewer", message: "ping")])
  end

  # ── a branch is a chain ──────────────────────────────────────────────

  test "a branch whose rounds repeat fails its round; its consumer reads the word and the spine runs on" do
    agent_loop = seed(model("ask", "tools" => [READ_TOOL, Nexus::Tools::TASK]))
    start!(agent_loop)
    spine = kernel_round!(agent_loop, "ask", [call("task", prompt: "Wait until status.txt says READY.", wait: true)],
      [AgentLoops::TaskToolJob])

    key = AgentLoops::TaskTool::Run.root_key("#{spine}t0")
    (window + 1).times do
      apply_via(attempt_for(agent_loop, key), sse_success("checking", tool_calls: [read("status.txt")]))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      refute_equal "failed", node(agent_loop, key).status, "#{key} was refused: #{node(agent_loop, key).error_detail}"
      schedule_loop!(agent_loop)
      branch = continuation_of(agent_loop, key)
      assert_equal "branch", branch.continuation_source
      assert_predicate AgentLoops::Parks::Settle.call(node: node(agent_loop, "#{branch.node_key}t0"), trusted: true,
        content: "NOT READY", outcome: "completed"), :applied?
      schedule_loop!(agent_loop)
      key = branch.node_key
    end
    refused!(agent_loop, key, [read("status.txt")])
    assert_equal "absorb", node(agent_loop, key).on_failure

    schedule_loop!(agent_loop)
    assert_equal "running", node(agent_loop, spine).status, "the spine reads the failed branch and runs on"
    paired = round_request_entries(node(agent_loop, spine))
      .find { |entry| entry["type"] == "tool_result_item" && entry.dig("payload", "call_id") == "call_task" }
      .dig("payload", "output")
    assert_includes paired, "<task_result task=\"#{spine}t0\" status=\"failed\">"
    assert_includes paired, "#{AgentLoops::ExpandRound::EXPANSION_REFUSED}: #{AgentLoops::RepeatBrake::REPEAT_LOOP}"
    answer!(agent_loop, spine, "the build never became ready")
    assert_equal "completed", agent_loop.reload.status
  end
end
