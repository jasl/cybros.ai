require "test_helper"
require "test_helpers/log_capture"

# THE REPEAT BRAKE judges NOVELTY, never count. A round is what its reader newly read — each call
# with its settled result, and the material delivered beside them — and it is stale when the rounds
# before it on the same chain already brought every element and nothing new reached its reader.
# Expansion is refused when the window of rounds up to the one the model just read are all stale and
# the model asks only for calls the lookback made. Every count here reads the kernel's window (K),
# and the refusal's word is compared byte for byte. Driven through the real chain: the round's call,
# the fan, the runner's answer, the continuation.
class Runs::RepeatBrakeTest < ActiveJob::TestCase
  include InvocationHarness
  include LogCapture

  READ_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_file", "parameters" => { "type" => "object" } },
  }.freeze
  # The runner's process poll and its shell, as the model spells them.
  PROCESS_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_process", "parameters" => { "type" => "object" } },
  }.freeze
  BASH_TOOL = {
    "type" => "function",
    "function" => { "name" => "bash", "parameters" => { "type" => "object" } },
  }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def model(key, **over) = super(key, "tools" => [READ_TOOL], **over)

  # K, read off the kernel.
  def window = Runs::RepeatBrake::NOVELTY_WINDOW

  def start!(run)
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    clear_enqueued_jobs
    schedule!(run)
  end

  def schedule!(run)
    Runs::ScheduleReady.call(run_id: run.id)
    clear_enqueued_jobs
  end

  def node(run, key) = run.tasks.find_by!(node_key: key)

  def step_attempt(run, key)
    @admitted ||= {}
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @admitted[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    clear_enqueued_jobs
    @admitted.fetch(node(run, key).selected_model_invocation_id)
  end

  def run_step!(run, behaviour, key:)
    apply_via(step_attempt(run, key), behaviour)
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(run)
  end

  # What an external runner does: the parked call settled with its content.
  def submit!(run, key, content:, **settle)
    Runs::Parks::Settle.call(node: node(run, key), trusted: true, content: content,
      outcome: "completed", **settle)
  end

  def said(text) = { content: text }

  # A result the prune arm can clear: bigger than the placeholder it leaves.
  def bulky(text) = said("#{text}\n#{"." * 2048}")

  def calls(*paths)
    paths.each_with_index.map do |path, index|
      { id: "call_#{index}", name: "read_file", arguments: "{\"path\":\"#{path}\"}" }
    end
  end

  def poll(id) = { id: "call_poll", name: "read_process", arguments: { id: id, tail_lines: 20 }.to_json }

  def bash(command) = { id: "call_bash", name: "bash", arguments: { command: command }.to_json }

  # Round n of a status check alternating with a poll of a silent process: the check on even n.
  def check_or_poll(n) = n.even? ? [[bash("cat status.txt")], [said("NOT READY")]] : [[poll("p2")], [said("line 20")]]

  # One round: the model at `key` asks `tool_calls`, the fan expands, each call is answered with
  # its `answers` entry (Settle's words), `prepare` runs on the queued continuation, and the
  # continuation is scheduled. Answers the continuation's key.
  def round!(run, key, tool_calls, answers, prepare: nil)
    run_step!(run, sse_success("again", tool_calls: tool_calls), key: key)
    asked = node(run, key)
    refute_equal "failed", asked.status, "#{key} was refused: #{asked.error_key} #{asked.error_detail}"
    continuation = continuation_of(run, key)
    answers.each_with_index do |answer, index|
      assert_predicate submit!(run, "#{continuation.node_key}t#{index}", **answer), :applied?
    end
    prepare&.call(continuation)
    schedule!(run)
    continuation.node_key
  end

  # The round a model node's calls expanded into — the mainline's or a branch's alike.
  def continuation_of(run, key)
    run.tasks.where("? = ANY(input_from_node_keys)", key)
      .find_by!(expansion_parent_id: node(run, key).id, type: Tasks::ModelTask.sti_name)
  end

  # `count` rounds from `key`, round n asking and answered as the block says; every one expands.
  def repeat!(run, key, count)
    count.times { |n| key = round!(run, key, *yield(n)) }
    key
  end

  def refused!(run, key, tool_calls)
    run_step!(run, sse_success("again", tool_calls: tool_calls), key: key)
    stalled = node(run, key)
    assert_equal %w[failed round_expansion_refused], [stalled.status, stalled.error_key], "#{key} was not refused"
    assert_equal Runs::RepeatBrake::REPEAT_LOOP, stalled.error_detail
    stalled
  end

  def refusals(run) = run.tasks.where(error_key: Runs::ExpandRound::EXPANSION_REFUSED)

  def mcp_declaration(label, remote_name: "search")
    connection = users(:owner).mcp_connections.create!(name: label,
      endpoint_url: "https://tools.example.test/mcp", auth_type: "none",
      catalog: [{ "name" => remote_name, "description" => "Remote tool", "input_schema" => { "type" => "object" } }])
    { "type" => "function", "function" => { "name" => label, "parameters" => { "type" => "object" } },
      "route" => { "kind" => "mcp", "connection_public_id" => connection.public_id, "tool_name" => remote_name } }
  end

  test "the same remote name on another connection is new and repeating that connection is still braked" do
    declarations = [mcp_declaration("personal_search"), mcp_declaration("work_search")]
    run = seed(model("ask", "tools" => declarations), creating_user: users(:agent), default_runner_executor_public_id: nil)
    start!(run)
    personal = [{ id: "search", name: "personal_search", arguments: "{}" }]
    work = [{ id: "search", name: "work_search", arguments: "{}" }]
    key = repeat!(run, "ask", window + 1) { [personal, [said("unchanged")]] }
    key = round!(run, key, work, [said("unchanged")])
    key = repeat!(run, key, window) { [work, [said("unchanged")]] }
    refused!(run, key, work)
  end

  test "a remote read_process has no implicit polling exemption" do
    run = seed(model("ask", "tools" => [mcp_declaration("remote_poll", remote_name: "read_process")]),
      creating_user: users(:agent), default_runner_executor_public_id: nil)
    start!(run)
    request = [{ id: "poll", name: "remote_poll", arguments: "{}" }]
    key = repeat!(run, "ask", window + 1) { [request, [said("unchanged")]] }
    refused!(run, key, request)
  end

  test "changing remote spawn results remain new instead of becoming kernel launch receipts" do
    run = seed(model("ask", "tools" => [mcp_declaration("remote_spawn", remote_name: "spawn")]),
      creating_user: users(:agent), default_runner_executor_public_id: nil)
    start!(run)
    request = [{ id: "spawn", name: "remote_spawn", arguments: "{}" }]
    repeat!(run, "ask", window + 2) { |index| [request, [said("remote result #{index}")]] }
    assert_empty refusals(run)
  end

  # ── the rule ─────────────────────────────────────────────────────────

  test "a pure repeat is refused at its (K+2)th call: K+1 identical rounds expand and the next halts" do
    run = seed(model("ask"))
    start!(run)

    key = repeat!(run, "ask", window + 1) { [calls("status.txt"), [said("NOT READY")]] }
    assert_equal "r#{window + 1}", key

    refused!(run, key, calls("status.txt"))
    assert_nil run.tasks.find_by(node_key: "r#{window + 2}t0"), "a refused expansion mints no fan"
    Runs::EvaluateQuiescence.call(run.reload)
    assert_equal "needs_attention", run.reload.status, "the refusal halts to a human"
  end

  test "a rotation whose results never change is refused K rounds after its last new result" do
    run = seed(model("ask"))
    start!(run)
    paths = %w[a b c]

    # Fans 1-3 bring something new, fans 4..K+3 bring nothing: the twelfth call is refused.
    key = repeat!(run, "ask", window + 3) { |n| [calls(paths[n % 3]), [said("contents of #{paths[n % 3]}")]] }
    refused!(run, key, calls(paths[(window + 3) % 3]))
  end

  test "an identical call whose result changes is never refused: a queue drained an item a call" do
    run = seed(model("ask"))
    start!(run)

    key = repeat!(run, "ask", (2 * window) + 2) { |n| [calls("queue"), [said("item-#{n}")]] }
    assert_equal "running", node(run, key).status
    assert_empty refusals(run)
  end

  test "an alternation whose results change is not a repeat" do
    run = seed(model("ask"))
    start!(run)
    paths = %w[a b]

    key = repeat!(run, "ask", (2 * window) + 2) { |n| [calls(paths[n % 2]), [said("#{paths[n % 2]} at #{n}")]] }
    assert_equal "running", node(run, key).status
    assert_empty refusals(run)
  end

  test "one member whose result changes keeps a whole fan new" do
    run = seed(model("ask"))
    start!(run)

    key = repeat!(run, "ask", (2 * window) + 2) { |n| [calls("a", "b"), [said("same"), said("n#{n}")]] }
    assert_equal "running", node(run, key).status
    assert_empty refusals(run)
  end

  test "a poll beside a repeated command is the command repeating" do
    run = seed(model("ask", "tools" => [READ_TOOL, PROCESS_TOOL, BASH_TOOL]))
    start!(run)

    key = repeat!(run, "ask", window + 1) { [[poll("p2"), bash("make test")], [said("same"), said("same")]] }
    refused!(run, key, [poll("p2"), bash("make test")])
  end

  # Polling a process the model started is the runner's designed wait — nothing wakes a loop on a
  # process exit — so a round of nothing but `read_process` calls is never refused, however long.
  test "pure polls are exempt" do
    run = seed(model("ask", "tools" => [READ_TOOL, PROCESS_TOOL]))
    start!(run)

    key = repeat!(run, "ask", window + 3) { [[poll("p2")], [said("line 20")]] }
    assert_equal "running", node(run, key).status, "the loop keeps waiting with the model"
    assert_empty refusals(run)
  end

  # A pure-poll round takes no place in the count: it neither extends a stale stretch nor breaks
  # one, so a status check alternating with a poll of a silent process is still caught.
  test "polls are transparent: they neither extend nor break a stale stretch" do
    run = seed(model("ask", "tools" => [READ_TOOL, PROCESS_TOOL, BASH_TOOL]))
    start!(run)
    check = [bash("cat status.txt")]

    # Nine `cat` rounds (one new, eight stale) interleaved with eight polls.
    key = repeat!(run, "ask", 17) { |n| check_or_poll(n) }
    key = round!(run, key, *check_or_poll(1))
    assert_empty refusals(run), "a poll after eight stale checks is never refused"

    refused!(run, key, check)
  end

  # THE ALIAS RESOLVES at authoring, so the rows carry the kernel's `task` and the brake reads the
  # row's words. A background `task` that launched is identified as a launch: its receipt's key and
  # reference are the kernel's, never novelty, and the work it launched is judged when it lands.
  test "the brake reads through an alias, and a repeated background launch is a repeat" do
    run = seed(model("ask", "prompt" => "delegate", "tools" => [READ_TOOL, RunLaneTestHelper::AGENT_ALIAS]))
    start!(run)

    key = "ask"
    (window + 1).times do |round|
      key = alias_round!(run, key, "review the diff")
      call = node(run, "#{key}t0")
      assert_equal ["delegate_task", "Agent", "completed"], [call.tool_name, call.tool_alias, call.status],
        "round #{round + 1}: the detached call answered at once"
    end

    apply_via(step_attempt(run, key), sse_success("delegating", tool_calls: [agent_call("review the diff")]))
    Runs::ConvergeTerminalSteps.call
    stalled = node(run, key)
    assert_equal %w[failed round_expansion_refused], [stalled.status, stalled.error_key]
    assert_equal Runs::RepeatBrake::REPEAT_LOOP, stalled.error_detail
  end

  test "different background work each round is new" do
    run = seed(model("ask", "prompt" => "delegate", "tools" => [READ_TOOL, RunLaneTestHelper::AGENT_ALIAS]))
    start!(run)

    key = "ask"
    ((2 * window) + 2).times do |round|
      key = alias_round!(run, key, "review part #{round}")
      assert_equal "completed", node(run, "#{key}t0").status, "round #{round + 1} expanded"
    end
    assert_empty refusals(run)
  end

  def agent_call(prompt) = { id: "call_0", name: "Agent", arguments: { prompt: prompt }.to_json }

  # The alias round: the model spells `Agent`, the kernel's `task` runs detached and its call settles
  # at once; the background work then answers on its own, so it holds no model slot while the mainline
  # goes on (its answer waits for the mainline to idle). Answers the continuation's key.
  def alias_round!(run, key, prompt)
    apply_via(step_attempt(run, key), sse_success("delegating", tool_calls: [agent_call(prompt)]))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    asked = node(run, key)
    refute_equal "failed", asked.status, "#{key} was refused: #{asked.error_key} #{asked.error_detail}"
    perform_enqueued_jobs(only: [Runs::DelegateTaskToolJob, Runs::ScheduleJob]) do
      Runs::ScheduleReady.call(run_id: run.id)
    end
    clear_enqueued_jobs
    continuation = continuation_of(run, key).node_key
    run_step!(run, sse_success("reviewed"), key: Runs::DelegateTaskTool::Run.root_key("#{continuation}t0"))
    continuation
  end

  # A call over the tool-input bound is a row that stores none of its arguments, failed for its
  # size: a model resending the same oversized write is not reading the failure it was handed. The
  # lane is windowless so each continuation replays the model's own oversized arguments without
  # arming compaction.
  test "an oversized call reads as its row stores it" do
    run = seed(model("ask", "model" => { "model" => DevModelLane::WINDOWLESS_TEXT_MODEL }))
    start!(run)
    big = { id: "call_big", name: "read_file", arguments: { "path" => "/tmp/big", "content" => "x" * 70_000 }.to_json }

    key = repeat!(run, "ask", window + 1) { [[big], []] }
    assert_equal ["failed", "tool_input_too_large", {}], node(run, "#{key}t0").values_at(:status, :error_key, :tool_input)

    refused!(run, key, [big])
  end

  # ── what makes a round new regardless ────────────────────────────────

  test "a landed steer makes its round new: the stretch restarts after it" do
    run = seed(model("ask"))
    start!(run)
    same = [calls("status.txt"), [said("NOT READY")]]

    key = repeat!(run, "ask", window - 1) { same }
    key = round!(run, key, *same, prepare: lambda { |continuation|
      assert_predicate loop_input!(run, acting_user: @human, text: "keep checking"), :accepted?
      assert_equal "queued", continuation.reload.status
    })
    assert_equal "r#{window}", key
    assert Runs::Steers::Landed.bodies_by_round([node(run, key)]).key?(node(run, key).id),
      "the steer landed on the reader of fan K"

    # Where a pure repeat was refused (the reader of fan K+1), this one expands; the refusal
    # comes K rounds after the steer's round.
    key = repeat!(run, key, window) { same }
    assert_equal "r#{2 * window}", key
    refused!(run, key, calls("status.txt"))
  end

  test "an ask's answer makes its round new: the stretch restarts after it" do
    run = seed(model("ask", "tools" => [READ_TOOL, Nexus::Tools::ASK]))
    start!(run)
    same = [calls("status.txt"), [said("NOT READY")]]

    key = repeat!(run, "ask", window - 1) { same }
    apply_via(step_attempt(run, key), sse_success("asking", tool_calls: calls("status.txt") + [
      { id: "call_ask", name: "ask", arguments: { prompt: "Keep checking?" }.to_json },
    ]))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [Runs::AskJob, Runs::ScheduleJob]) do
      Runs::ScheduleReady.call(run_id: run.id)
    end
    clear_enqueued_jobs
    key = "r#{window}"
    assert_predicate submit!(run, "#{key}t0", content: "NOT READY"), :applied?
    await = node(run, "#{key}t1-ask-1")
    assert_predicate Runs::Parks::Settle.call(node: await, content: "yes, keep checking"), :applied?
    schedule!(run)
    assert_equal "running", node(run, key).status, "the reader of fan K read the person's answer"

    key = repeat!(run, key, window) { same }
    refused!(run, key, calls("status.txt"))
  end

  # A person who fixed the world and pressed retry gets the call that shows it: the re-run reader
  # is new, so the retry verb on a brake halt never refuses again before anything runs.
  test "a person's retry of the refused round makes it new, and the brake speaks again K rounds later" do
    run = seed(model("ask"))
    start!(run)
    same = [calls("status.txt"), [said("NOT READY")]]

    key = repeat!(run, "ask", window + 1) { same }
    refused!(run, key, calls("status.txt"))
    retry!(run, key)

    key = repeat!(run, key, window) { same }
    assert_equal "r#{(2 * window) + 1}", key
    refused!(run, key, calls("status.txt"))
  end

  # The person's retry of a refused round, up to the re-run reader asking again.
  def retry!(run, key)
    Runs::EvaluateQuiescence.call(run.reload)
    retried = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run.reload, task_key: key, acting_user: @human
    ))
    assert_predicate retried, :accepted?
    schedule!(run)
    assert_equal ["running", 1], node(run, key).values_at(:status, :execution_generation)
  end

  # A poll round is transparent only while it is nothing but polls. When something new reached its
  # reader — the round the model asks from — the round stays in the count as new, and slides out of
  # the window after K judged rounds: a retry or a steer on the reader of a poll fan is never lost.
  test "a person's retry of a refusal at the reader of a poll round makes it new" do
    run = seed(model("ask", "tools" => [READ_TOOL, PROCESS_TOOL, BASH_TOOL]))
    start!(run)
    check = [bash("cat status.txt")]

    key = repeat!(run, "ask", 17) { |n| check_or_poll(n) }
    retried = round!(run, key, *check_or_poll(1))
    refused!(run, retried, check)
    retry!(run, retried)

    # The re-run reader's check expands; K stale checks after it — the polls between them
    # transparent again — the check is refused.
    key = repeat!(run, retried, 2 * window) { |n| check_or_poll(n) }
    assert_equal "r#{retried.delete_prefix("r").to_i + (2 * window)}", key
    refused!(run, key, check)
  end

  test "a steer that lands on the reader of a poll round makes it new" do
    run = seed(model("ask", "tools" => [READ_TOOL, PROCESS_TOOL, BASH_TOOL]))
    start!(run)
    check = [bash("cat status.txt")]

    key = repeat!(run, "ask", 17) { |n| check_or_poll(n) }
    steered = round!(run, key, *check_or_poll(1), prepare: lambda { |continuation|
      assert_predicate loop_input!(run, acting_user: @human, text: "keep checking"), :accepted?
      assert_equal "queued", continuation.reload.status
    })
    assert Runs::Steers::Landed.bodies_by_round([node(run, steered)]).key?(node(run, steered).id),
      "the steer landed on the reader of the poll fan"

    # Where the plain alternation's check is refused, this one expands; K stale checks later it is.
    key = repeat!(run, steered, 2 * window) { |n| check_or_poll(n) }
    assert_equal "r#{steered.delete_prefix("r").to_i + (2 * window)}", key
    refused!(run, key, check)
  end

  # ── what ends the walk ───────────────────────────────────────────────

  # What re-opened the chain past a call-less answer — here a queued word the kernel plants a
  # follow-up for — was new; a stretch never spans it.
  test "a round that made no call ends the walk" do
    run = seed(model("ask"))
    start!(run)
    same = [calls("status.txt"), [said("NOT READY")]]

    key = repeat!(run, "ask", window) { same }
    queued = loop_input!(run, acting_user: @human, text: "check once more", delivery_mode: "queue")
    assert_predicate queued, :accepted?
    run_step!(run, sse_success("still not ready"), key: key)
    assert_equal "completed", node(run, key).status, "the round answered without a call"
    schedule!(run)
    assert_equal "running", node(run, "w1").status, "the kernel planted a follow-up for the queued word"

    key = repeat!(run, "w1", window) { same }
    run_step!(run, sse_success("again", tool_calls: calls("status.txt")), key: key)
    assert_equal "completed", node(run, key).status, "the stretch before the call-less round is outside the window"
    assert_empty refusals(run)
  end

  # A pruned round's reader composed under a repair whose placeholder says to call the tool again:
  # the re-reads that follow are new by the ruling's own measure. And the brake reads ROWS: a
  # cleared result keeps its identity, so a drain's changing results stay new under the prune.
  test "a prune mark ends the walk, and rows, never the cleared placeholder, are read" do
    run = seed(model("ask"))
    start!(run)
    prune = lambda do |continuation|
      repair = Conversations::Compaction::Arm.call(run: run, node: continuation,
        trigger: Conversations::Compaction::Trigger.wall(continuation,
          overshoot: Conversations::Compaction::Overshoot.bytes(1)))
      assert_predicate repair, :pruned?
    end

    key = repeat!(run, "ask", window - 1) { |n| [calls("queue"), [bulky("item-#{n}")]] }
    key = round!(run, key, calls("queue"), [bulky("item-#{window}")], prepare: prune)
    key = repeat!(run, key, (2 * window) + 2) { |n| [calls("queue"), [bulky("item-#{window + 1 + n}")]] }
    assert_equal "running", node(run, key).status
    assert_empty refusals(run), "a drain under the prune arm is never refused"
  end

  test "after a prune mark a repeat is refused only once K rounds after the mark brought nothing new" do
    run = seed(model("ask"))
    start!(run)
    same = [calls("status.txt"), [bulky("NOT READY")]]
    prune = lambda do |continuation|
      repair = Conversations::Compaction::Arm.call(run: run, node: continuation,
        trigger: Conversations::Compaction::Trigger.wall(continuation,
          overshoot: Conversations::Compaction::Overshoot.bytes(1)))
      assert_predicate repair, :pruned?
    end

    key = repeat!(run, "ask", 4) { same }
    marked = round!(run, key, *same, prepare: prune)
    assert_predicate node(run, marked), :repaired?

    # The mark's reader asks, then K+1 more rounds expand: the first fan after the mark is new,
    # the K after it are stale, and only then is the repeat refused.
    key = repeat!(run, marked, window + 1) { same }
    assert_equal "r#{marked.delete_prefix("r").to_i + window + 1}", key
    refused!(run, key, calls("status.txt"))
  end

  test "after an arrived summary a repeat is refused only once K rounds after the mark brought nothing new" do
    run = seed(model("ask"))
    start!(run)
    same = [calls("status.txt"), [said("NOT READY")]]
    summary_key = nil
    summarize = lambda do |continuation|
      repair = Conversations::Compaction::Arm.call(run: run, node: continuation,
        trigger: Conversations::Compaction::Trigger.manual(user: @human))
      assert repair, "the repair arms on the continuation"
      summary_key = repair.summary_task_key
    end

    key = repeat!(run, "ask", 4) { same }
    marked = round!(run, key, *same, prepare: summarize)
    run_step!(run, sse_success("the file said NOT READY four times"), key: summary_key)
    assert_equal "running", node(run, marked).status
    assert_predicate node(run, marked).arrived_summary, :present?

    key = repeat!(run, marked, window + 1) { same }
    refused!(run, key, calls("status.txt"))
  end

  # ── what a result is ─────────────────────────────────────────────────

  # A `resource_link` carries a fresh upload id per call and `structured` is the UI's channel:
  # neither makes a repeated tool operation new; capture handles alone are not progress.
  test "links and structure are not identity" do
    run = seed(model("ask"))
    start!(run)

    key = repeat!(run, "ask", window + 1) do |n|
      log = capture("run-#{n}.log", "line #{n}\n", "text/plain")
      [calls("suite"), [{ content: [{ "type" => "text", "text" => "3 failures" }, link(log)],
                          structured_content: { "run" => n }, creator: @human }]]
    end
    refused!(run, key, calls("suite"))
  end

  test "pictures are identity: the same bytes repeat, different bytes are new" do
    unchanged = seed(model("ask"))
    start!(unchanged)
    key = repeat!(unchanged, "ask", window + 1) do |n|
      shot = capture("shot-#{n}.png", PngFixture.bytes(width: 2, height: 2), "image/png")
      [calls("page"), [{ content: [{ "type" => "text", "text" => "saved" }, link(shot)], creator: @human }]]
    end
    refused!(unchanged, key, calls("page"))

    changing = seed(model("ask"))
    start!(changing)
    key = repeat!(changing, "ask", (2 * window) + 2) do |n|
      shot = capture("shot-#{n}.png", PngFixture.bytes(width: 2, height: 2, rgb: [n, 0, 0].pack("C3")), "image/png")
      [calls("page"), [{ content: [{ "type" => "text", "text" => "saved" }, link(shot)], creator: @human }]]
    end
    assert_equal "running", node(changing, key).status
    assert_empty refusals(changing)
  end

  def capture(filename, bytes, content_type)
    @account.content_uploads.create!(
      creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename, content_type: content_type)
    )
  end

  def link(upload)
    { "type" => "resource_link", "uri" => "nexus://uploads/#{upload.public_id}", "name" => upload.filename.to_s }
  end

  # ── the window ───────────────────────────────────────────────────────

  # The window is the K rounds up to the one the model just read, and the oldest of them is judged
  # too: one that brought something new spares the refusal; one more stale round and it is due.
  test "the oldest judged round bringing something new spares the refusal" do
    run = seed(model("ask"))
    start!(run)

    key = round!(run, "ask", calls("other"), [said("elsewhere")])
    key = repeat!(run, key, window) { [calls("status.txt"), [said("NOT READY")]] }
    run_step!(run, sse_success("again", tool_calls: calls("status.txt")), key: key)
    assert_equal "completed", node(run, key).status, "the oldest judged round brought the first NOT READY"
    submit!(run, "r#{window + 2}t0", content: "NOT READY")
    schedule!(run)

    refused!(run, "r#{window + 2}", calls("status.txt"))
  end

  # The window's readers ride the kernel's log line, never a model-facing sentence: the detail
  # stays the closed word on every surface.
  test "the refusal logs the window's readers" do
    run = seed(model("ask"))
    start!(run)
    key = repeat!(run, "ask", window + 1) { [calls("status.txt"), [said("NOT READY")]] }

    lines = capture_log { refused!(run, key, calls("status.txt")) }
    logged = lines.grep(/event=run_repeat_refused/)
    assert_equal ["event=run_repeat_refused loop=#{run.public_id} task=#{key} window_first=r2 " \
                  "window_last=#{key} window=#{window} calls=1"], logged.map(&:strip)
  end
end
