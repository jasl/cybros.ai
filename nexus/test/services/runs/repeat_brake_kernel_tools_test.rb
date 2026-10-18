require "test_helper"

# THE REPEAT BRAKE over the kernel's own verbs. A waited `task` and a `wait` are judged by the tip the
# reader held — the branch's last word, the observing await — never by the launch receipt; a
# background launch (`task`, `spawn`, `send`) is identified as a launch, since the receipt's
# only varying bytes are the kernel's own key; delivered material is judged by where it came from and
# what it said. And a branch is a chain like the mainline: its refusal fails the branch's round, which
# its consumer reads, and the mainline runs on.
class Runs::RepeatBrakeKernelToolsTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def window = Runs::RepeatBrake::NOVELTY_WINDOW

  def start!(run)
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    clear_enqueued_jobs
    schedule_loop!(run)
  end

  def node(run, key) = run.tasks.find_by!(node_key: key)

  def attempt_for(run, key)
    invocation_id = node(run, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def answer!(run, key, text)
    apply_via(attempt_for(run, key), sse_success(text))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule_loop!(run)
  end

  # The model at `key` makes `tool_calls`, the fan expands and the kernel's jobs run. Answers the
  # continuation's key.
  def kernel_round!(run, key, tool_calls, jobs)
    apply_via(attempt_for(run, key), sse_success("working", tool_calls: tool_calls))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    asked = node(run, key)
    refute_equal "failed", asked.status, "#{key} was refused: #{asked.error_key} #{asked.error_detail}"
    perform_enqueued_jobs(only: [*jobs, Runs::ScheduleJob]) do
      Runs::ScheduleReady.call(run_id: run.id)
    end
    clear_enqueued_jobs
    continuation_of(run, key).node_key
  end

  def continuation_of(run, key)
    run.tasks.where("? = ANY(input_from_node_keys)", key)
      .find_by!(expansion_parent_id: node(run, key).id, type: Tasks::ModelTask.sti_name)
  end

  def refused!(run, key, tool_calls)
    apply_via(attempt_for(run, key), sse_success("working", tool_calls: tool_calls))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    stalled = node(run, key)
    assert_equal %w[failed round_expansion_refused], [stalled.status, stalled.error_key], "#{key} was not refused"
    assert_equal Runs::RepeatBrake::REPEAT_LOOP, stalled.error_detail
    stalled
  end

  def refusals(run) = run.tasks.where(error_key: Runs::ExpandRound::EXPANSION_REFUSED)

  def call(name, **arguments) = { id: "call_#{name}", name: name, arguments: arguments.to_json }

  def read(path) = { id: "call_read", name: "read_file", arguments: { path: path }.to_json }

  # ── a waited task ────────────────────────────────────────────────────

  # One mainline round asking the same waited `task`; its branch answers `text`, and the continuation
  # reads that answer as the call's paired result. Answers the continuation's key.
  def waited_task_round!(run, key, text)
    continuation = kernel_round!(run, key, [call("delegate_task", prompt: "Is the build ready?", wait: true)],
      [Runs::DelegateTaskToolJob])
    answer!(run, Runs::DelegateTaskTool::Run.root_key("#{continuation}t0"), text)
    assert_equal "running", node(run, continuation).status, "the continuation read the branch's answer"
    continuation
  end

  test "a waited task is judged by its branch's answer: the same answer repeats, a changing one is new" do
    unchanged = seed(model("ask", "tools" => [READ_TOOL, Nexus::Tools::DELEGATE_TASK]))
    start!(unchanged)
    key = "ask"
    (window + 1).times { key = waited_task_round!(unchanged, key, "NOT READY") }
    refused!(unchanged, key, [call("delegate_task", prompt: "Is the build ready?", wait: true)])

    changing = seed(model("ask", "tools" => [READ_TOOL, Nexus::Tools::DELEGATE_TASK]))
    start!(changing)
    key = "ask"
    ((2 * window) + 2).times { |n| key = waited_task_round!(changing, key, "item-#{n}") }
    assert_empty refusals(changing)
  end

  # ── wait ─────────────────────────────────────────────────────────────

  # One mainline round waiting on `target` for a second: the await observes work already done at once,
  # else times out; the continuation reads the await as the call's result.
  def wait_round!(run, key, target)
    continuation = kernel_round!(run, key, [call("wait", task: target, timeout_ms: 1_000)],
      [Runs::WaitToolJob])
    await = node(run, "#{continuation}t0#{Runs::WaitTool::Run::SUFFIX}")
    # The scheduler reconciles a dispatched await against its target; one still working times out.
    schedule_loop!(run)
    unless await.reload.terminal?
      travel(2.seconds) { DatabaseClock.stub(:now, Time.current) { Runs::Parks::TimeoutSweep.call } }
    end
    schedule_loop!(run)
    assert_equal "running", node(run, continuation).status, "the continuation read the await"
    continuation
  end

  def launch!(run, key, *prompts)
    kernel_round!(run, key, prompts.each_with_index.map { |prompt, index|
      { id: "call_#{index}", name: "delegate_task", arguments: { prompt: prompt }.to_json }
    }, [Runs::DelegateTaskToolJob])
  end

  test "a wait is judged by its await: new while completions arrive, a repeat on work that hangs" do
    tools = [READ_TOOL, Nexus::Tools::DELEGATE_TASK, Nexus::Tools::WAIT]
    rotating = seed(model("ask", "tools" => tools))
    start!(rotating)
    launched = launch!(rotating, "ask", "build one", "build two", "build three")
    targets = (0..2).map { |index| "#{launched}t#{index}" }
    # Each target answers a few rounds before the wait that finds it done.
    finishes = { 6 => targets[0], 10 => targets[1], 14 => targets[2] }

    key = launched
    ((2 * window) + 2).times do |n|
      answer!(rotating, Runs::DelegateTaskTool::Run.root_key(finishes[n]), "#{finishes[n]} done") if finishes[n]
      key = wait_round!(rotating, key, targets[n % 3])
    end
    assert_empty refusals(rotating), "a rotation of waits is new while completions arrive"

    hung = seed(model("ask", "tools" => tools))
    start!(hung)
    launched = launch!(hung, "ask", "build forever")
    key = launched
    (window + 1).times do
      key = wait_round!(hung, key, "#{launched}t0")
      await = node(hung, "#{key}t0#{Runs::WaitTool::Run::SUFFIX}")
      assert_equal %w[timed_out await_timeout], [await.status, await.error_key]
    end
    refused!(hung, key, [call("wait", task: "#{launched}t0", timeout_ms: 1_000)])
  end

  # ── send ─────────────────────────────────────────────────────────────

  # A `send` to one's own child returns a receipt naming the call's key: the kernel's own byte,
  # never novelty. The same message to the same child, round after round, is a repeat.
  test "a send to one's own child repeated is a repeat" do
    declare_tools!(@agent, tools: [Nexus::Tools::SPAWN, Nexus::Tools::SEND, READ_TOOL])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    post_input!(conversation, acting_user: @human, text: "go")
    _turn, run = materialize_loop_reply!(conversation, agent: @agent, text: nil)
    schedule_loop!(run)

    key = kernel_round!(run, "r1", [call("spawn", prompt: "Review the diff.", label: "reviewer")],
      [Runs::ConversationToolJob])
    (window + 1).times do
      key = kernel_round!(run, key, [call("send", to: "reviewer", message: "ping")],
        [Runs::ConversationToolJob])
      assert_match(/\ASent to /, node(run, "#{key}t0").output_body.effective_text)
    end
    refused!(run, key, [call("send", to: "reviewer", message: "ping")])
  end

  # ── a branch is a chain ──────────────────────────────────────────────

  test "a branch whose rounds repeat fails its round; its consumer reads the word and the mainline runs on" do
    run = seed(model("ask", "tools" => [READ_TOOL, Nexus::Tools::DELEGATE_TASK]))
    start!(run)
    mainline = kernel_round!(run, "ask", [call("delegate_task", prompt: "Wait until status.txt says READY.", wait: true)],
      [Runs::DelegateTaskToolJob])

    key = Runs::DelegateTaskTool::Run.root_key("#{mainline}t0")
    (window + 1).times do
      apply_via(attempt_for(run, key), sse_success("checking", tool_calls: [read("status.txt")]))
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      refute_equal "failed", node(run, key).status, "#{key} was refused: #{node(run, key).error_detail}"
      schedule_loop!(run)
      branch = continuation_of(run, key)
      assert_equal "branch", branch.continuation_source
      assert_predicate Runs::Parks::Settle.call(node: node(run, "#{branch.node_key}t0"), trusted: true,
        content: "NOT READY", outcome: "completed"), :applied?
      schedule_loop!(run)
      key = branch.node_key
    end
    refused!(run, key, [read("status.txt")])
    assert_equal "absorb", node(run, key).on_failure

    schedule_loop!(run)
    assert_equal "running", node(run, mainline).status, "the mainline reads the failed branch and runs on"
    paired = round_request_entries(node(run, mainline))
      .find { |entry| entry["type"] == "tool_result_item" && entry.dig("payload", "call_id") == "call_delegate_task" }
      .dig("payload", "output")
    assert_includes paired, "<task_result task=\"#{mainline}t0\" status=\"failed\">"
    assert_includes paired, "#{Runs::ExpandRound::EXPANSION_REFUSED}: #{Runs::RepeatBrake::REPEAT_LOOP}"
    answer!(run, mainline, "the build never became ready")
    assert_equal "completed", run.reload.status
  end
end
