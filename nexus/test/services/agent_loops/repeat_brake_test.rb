require "test_helper"
require "test_helpers/log_capture"

# THE REPEAT BRAKE judges NOVELTY, never count. A round is what its reader newly read — each call
# with its settled result, and the material delivered beside them — and it is stale when the rounds
# before it on the same chain already brought every element and nothing new reached its reader.
# Expansion is refused when the window of rounds up to the one the model just read are all stale and
# the model asks only for calls the lookback made. Every count here reads the kernel's window (K),
# and the refusal's word is compared byte for byte. Driven through the real chain: the round's call,
# the fan, the runner's answer, the continuation.
class AgentLoops::RepeatBrakeTest < ActiveJob::TestCase
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
  def window = AgentLoops::RepeatBrake::NOVELTY_WINDOW

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    clear_enqueued_jobs
    schedule!(agent_loop)
  end

  def schedule!(agent_loop)
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def step_attempt(agent_loop, key)
    @admitted ||= {}
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @admitted[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    clear_enqueued_jobs
    @admitted.fetch(node(agent_loop, key).selected_model_invocation_id)
  end

  def run_step!(agent_loop, behaviour, key:)
    apply_via(step_attempt(agent_loop, key), behaviour)
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_loop)
  end

  # What an external runner does: the parked call settled with its content.
  def submit!(agent_loop, key, content:, **settle)
    AgentLoops::Parks::Settle.call(node: node(agent_loop, key), trusted: true, content: content,
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
  def round!(agent_loop, key, tool_calls, answers, prepare: nil)
    run_step!(agent_loop, sse_success("again", tool_calls: tool_calls), key: key)
    asked = node(agent_loop, key)
    refute_equal "failed", asked.status, "#{key} was refused: #{asked.error_key} #{asked.error_detail}"
    continuation = continuation_of(agent_loop, key)
    answers.each_with_index do |answer, index|
      assert_predicate submit!(agent_loop, "#{continuation.node_key}t#{index}", **answer), :applied?
    end
    prepare&.call(continuation)
    schedule!(agent_loop)
    continuation.node_key
  end

  # The round a model node's calls expanded into — the spine's or a branch's alike.
  def continuation_of(agent_loop, key)
    agent_loop.agent_loop_nodes.where("? = ANY(input_from_node_keys)", key)
      .find_by!(expansion_parent_id: node(agent_loop, key).id, type: AgentLoopNodes::ModelTask.sti_name)
  end

  # `count` rounds from `key`, round n asking and answered as the block says; every one expands.
  def repeat!(agent_loop, key, count)
    count.times { |n| key = round!(agent_loop, key, *yield(n)) }
    key
  end

  def refused!(agent_loop, key, tool_calls)
    run_step!(agent_loop, sse_success("again", tool_calls: tool_calls), key: key)
    stalled = node(agent_loop, key)
    assert_equal %w[failed round_expansion_refused], [stalled.status, stalled.error_key], "#{key} was not refused"
    assert_equal AgentLoops::RepeatBrake::REPEAT_LOOP, stalled.error_detail
    stalled
  end

  def refusals(agent_loop) = agent_loop.agent_loop_nodes.where(error_key: AgentLoops::ExpandRound::EXPANSION_REFUSED)

  # ── the rule ─────────────────────────────────────────────────────────

  test "a pure repeat is refused at its (K+2)th call: K+1 identical rounds expand and the next halts" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)

    key = repeat!(agent_loop, "ask", window + 1) { [calls("status.txt"), [said("NOT READY")]] }
    assert_equal "r#{window + 1}", key

    refused!(agent_loop, key, calls("status.txt"))
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "r#{window + 2}t0"), "a refused expansion mints no fan"
    AgentLoops::EvaluateQuiescence.call(agent_loop.reload)
    assert_equal "needs_attention", agent_loop.reload.status, "the refusal halts to a human"
  end

  test "a rotation whose results never change is refused K rounds after its last new result" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)
    paths = %w[a b c]

    # Fans 1-3 bring something new, fans 4..K+3 bring nothing: the twelfth call is refused.
    key = repeat!(agent_loop, "ask", window + 3) { |n| [calls(paths[n % 3]), [said("contents of #{paths[n % 3]}")]] }
    refused!(agent_loop, key, calls(paths[(window + 3) % 3]))
  end

  test "an identical call whose result changes is never refused: a queue drained an item a call" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)

    key = repeat!(agent_loop, "ask", (2 * window) + 2) { |n| [calls("queue"), [said("item-#{n}")]] }
    assert_equal "running", node(agent_loop, key).status
    assert_empty refusals(agent_loop)
  end

  test "an alternation whose results change is not a repeat" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)
    paths = %w[a b]

    key = repeat!(agent_loop, "ask", (2 * window) + 2) { |n| [calls(paths[n % 2]), [said("#{paths[n % 2]} at #{n}")]] }
    assert_equal "running", node(agent_loop, key).status
    assert_empty refusals(agent_loop)
  end

  test "one member whose result changes keeps a whole fan new" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)

    key = repeat!(agent_loop, "ask", (2 * window) + 2) { |n| [calls("a", "b"), [said("same"), said("n#{n}")]] }
    assert_equal "running", node(agent_loop, key).status
    assert_empty refusals(agent_loop)
  end

  test "a poll beside a repeated command is the command repeating" do
    agent_loop = seed(model("ask", "tools" => [READ_TOOL, PROCESS_TOOL, BASH_TOOL]))
    start!(agent_loop)

    key = repeat!(agent_loop, "ask", window + 1) { [[poll("p2"), bash("make test")], [said("same"), said("same")]] }
    refused!(agent_loop, key, [poll("p2"), bash("make test")])
  end

  # Polling a process the model started is the runner's designed wait — nothing wakes a loop on a
  # process exit — so a round of nothing but `read_process` calls is never refused, however long.
  test "pure polls are exempt" do
    agent_loop = seed(model("ask", "tools" => [READ_TOOL, PROCESS_TOOL]))
    start!(agent_loop)

    key = repeat!(agent_loop, "ask", window + 3) { [[poll("p2")], [said("line 20")]] }
    assert_equal "running", node(agent_loop, key).status, "the loop keeps waiting with the model"
    assert_empty refusals(agent_loop)
  end

  # A pure-poll round takes no place in the count: it neither extends a stale stretch nor breaks
  # one, so a status check alternating with a poll of a silent process is still caught.
  test "polls are transparent: they neither extend nor break a stale stretch" do
    agent_loop = seed(model("ask", "tools" => [READ_TOOL, PROCESS_TOOL, BASH_TOOL]))
    start!(agent_loop)
    check = [bash("cat status.txt")]

    # Nine `cat` rounds (one new, eight stale) interleaved with eight polls.
    key = repeat!(agent_loop, "ask", 17) { |n| check_or_poll(n) }
    key = round!(agent_loop, key, *check_or_poll(1))
    assert_empty refusals(agent_loop), "a poll after eight stale checks is never refused"

    refused!(agent_loop, key, check)
  end

  # THE ALIAS RESOLVES at authoring, so the rows carry the kernel's `task` and the brake reads the
  # row's words. A background `task` that launched is identified as a launch: its receipt's key and
  # reference are the kernel's, never novelty, and the work it launched is judged when it lands.
  test "the brake reads through an alias, and a repeated background launch is a repeat" do
    agent_loop = seed(model("ask", "prompt" => "delegate", "tools" => [READ_TOOL, LoopLaneTestHelper::AGENT_ALIAS]))
    start!(agent_loop)

    key = "ask"
    (window + 1).times do |round|
      key = alias_round!(agent_loop, key, "review the diff")
      call = node(agent_loop, "#{key}t0")
      assert_equal ["task", "Agent", "completed"], [call.tool_name, call.tool_alias, call.status],
        "round #{round + 1}: the detached call answered at once"
    end

    apply_via(step_attempt(agent_loop, key), sse_success("delegating", tool_calls: [agent_call("review the diff")]))
    AgentLoops::ConvergeTerminalSteps.call
    stalled = node(agent_loop, key)
    assert_equal %w[failed round_expansion_refused], [stalled.status, stalled.error_key]
    assert_equal AgentLoops::RepeatBrake::REPEAT_LOOP, stalled.error_detail
  end

  test "different background work each round is new" do
    agent_loop = seed(model("ask", "prompt" => "delegate", "tools" => [READ_TOOL, LoopLaneTestHelper::AGENT_ALIAS]))
    start!(agent_loop)

    key = "ask"
    ((2 * window) + 2).times do |round|
      key = alias_round!(agent_loop, key, "review part #{round}")
      assert_equal "completed", node(agent_loop, "#{key}t0").status, "round #{round + 1} expanded"
    end
    assert_empty refusals(agent_loop)
  end

  def agent_call(prompt) = { id: "call_0", name: "Agent", arguments: { prompt: prompt }.to_json }

  # The alias round: the model spells `Agent`, the kernel's `task` runs detached and its call settles
  # at once; the background work then answers on its own, so it holds no model slot while the spine
  # goes on (its answer waits for the spine to idle). Answers the continuation's key.
  def alias_round!(agent_loop, key, prompt)
    apply_via(step_attempt(agent_loop, key), sse_success("delegating", tool_calls: [agent_call(prompt)]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    asked = node(agent_loop, key)
    refute_equal "failed", asked.status, "#{key} was refused: #{asked.error_key} #{asked.error_detail}"
    perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    clear_enqueued_jobs
    continuation = continuation_of(agent_loop, key).node_key
    run_step!(agent_loop, sse_success("reviewed"), key: AgentLoops::TaskTool::Run.root_key("#{continuation}t0"))
    continuation
  end

  # A call over the tool-input bound is a row that stores none of its arguments, failed for its
  # size: a model resending the same oversized write is not reading the failure it was handed. The
  # lane is windowless so each continuation replays the model's own oversized arguments without
  # arming compaction.
  test "an oversized call reads as its row stores it" do
    agent_loop = seed(model("ask", "model" => { "model" => DevModelLane::WINDOWLESS_TEXT_MODEL }))
    start!(agent_loop)
    big = { id: "call_big", name: "read_file", arguments: { "path" => "/tmp/big", "content" => "x" * 70_000 }.to_json }

    key = repeat!(agent_loop, "ask", window + 1) { [[big], []] }
    assert_equal ["failed", "tool_input_too_large", {}], node(agent_loop, "#{key}t0").values_at(:status, :error_key, :tool_input)

    refused!(agent_loop, key, [big])
  end

  # ── what makes a round new regardless ────────────────────────────────

  test "a landed steer makes its round new: the stretch restarts after it" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)
    same = [calls("status.txt"), [said("NOT READY")]]

    key = repeat!(agent_loop, "ask", window - 1) { same }
    key = round!(agent_loop, key, *same, prepare: lambda { |continuation|
      assert_predicate loop_input!(agent_loop, acting_user: @human, text: "keep checking"), :accepted?
      assert_equal "queued", continuation.reload.status
    })
    assert_equal "r#{window}", key
    assert AgentLoops::Steers::Landed.bodies_by_round([node(agent_loop, key)]).key?(node(agent_loop, key).id),
      "the steer landed on the reader of fan K"

    # Where a pure repeat was refused (the reader of fan K+1), this one expands; the refusal
    # comes K rounds after the steer's round.
    key = repeat!(agent_loop, key, window) { same }
    assert_equal "r#{2 * window}", key
    refused!(agent_loop, key, calls("status.txt"))
  end

  test "an ask's answer makes its round new: the stretch restarts after it" do
    agent_loop = seed(model("ask", "tools" => [READ_TOOL, Nexus::Tools::ASK]))
    start!(agent_loop)
    same = [calls("status.txt"), [said("NOT READY")]]

    key = repeat!(agent_loop, "ask", window - 1) { same }
    apply_via(step_attempt(agent_loop, key), sse_success("asking", tool_calls: calls("status.txt") + [
      { id: "call_ask", name: "ask", arguments: { prompt: "Keep checking?" }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentLoops::AskJob, AgentLoops::ScheduleJob]) do
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end
    clear_enqueued_jobs
    key = "r#{window}"
    assert_predicate submit!(agent_loop, "#{key}t0", content: "NOT READY"), :applied?
    await = node(agent_loop, "#{key}t1-ask-1")
    assert_predicate AgentLoops::Parks::Settle.call(node: await, content: "yes, keep checking"), :applied?
    schedule!(agent_loop)
    assert_equal "running", node(agent_loop, key).status, "the reader of fan K read the person's answer"

    key = repeat!(agent_loop, key, window) { same }
    refused!(agent_loop, key, calls("status.txt"))
  end

  # A person who fixed the world and pressed retry gets the call that shows it: the re-run reader
  # is new, so the retry verb on a brake halt never refuses again before anything runs.
  test "a person's retry of the refused round makes it new, and the brake speaks again K rounds later" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)
    same = [calls("status.txt"), [said("NOT READY")]]

    key = repeat!(agent_loop, "ask", window + 1) { same }
    refused!(agent_loop, key, calls("status.txt"))
    retry!(agent_loop, key)

    key = repeat!(agent_loop, key, window) { same }
    assert_equal "r#{(2 * window) + 1}", key
    refused!(agent_loop, key, calls("status.txt"))
  end

  # The person's retry of a refused round, up to the re-run reader asking again.
  def retry!(agent_loop, key)
    AgentLoops::EvaluateQuiescence.call(agent_loop.reload)
    retried = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop.reload, task_key: key, acting_user: @human
    ))
    assert_predicate retried, :accepted?
    schedule!(agent_loop)
    assert_equal ["running", 1], node(agent_loop, key).values_at(:status, :execution_generation)
  end

  # A poll round is transparent only while it is nothing but polls. When something new reached its
  # reader — the round the model asks from — the round stays in the count as new, and slides out of
  # the window after K judged rounds: a retry or a steer on the reader of a poll fan is never lost.
  test "a person's retry of a refusal at the reader of a poll round makes it new" do
    agent_loop = seed(model("ask", "tools" => [READ_TOOL, PROCESS_TOOL, BASH_TOOL]))
    start!(agent_loop)
    check = [bash("cat status.txt")]

    key = repeat!(agent_loop, "ask", 17) { |n| check_or_poll(n) }
    retried = round!(agent_loop, key, *check_or_poll(1))
    refused!(agent_loop, retried, check)
    retry!(agent_loop, retried)

    # The re-run reader's check expands; K stale checks after it — the polls between them
    # transparent again — the check is refused.
    key = repeat!(agent_loop, retried, 2 * window) { |n| check_or_poll(n) }
    assert_equal "r#{retried.delete_prefix("r").to_i + (2 * window)}", key
    refused!(agent_loop, key, check)
  end

  test "a steer that lands on the reader of a poll round makes it new" do
    agent_loop = seed(model("ask", "tools" => [READ_TOOL, PROCESS_TOOL, BASH_TOOL]))
    start!(agent_loop)
    check = [bash("cat status.txt")]

    key = repeat!(agent_loop, "ask", 17) { |n| check_or_poll(n) }
    steered = round!(agent_loop, key, *check_or_poll(1), prepare: lambda { |continuation|
      assert_predicate loop_input!(agent_loop, acting_user: @human, text: "keep checking"), :accepted?
      assert_equal "queued", continuation.reload.status
    })
    assert AgentLoops::Steers::Landed.bodies_by_round([node(agent_loop, steered)]).key?(node(agent_loop, steered).id),
      "the steer landed on the reader of the poll fan"

    # Where the plain alternation's check is refused, this one expands; K stale checks later it is.
    key = repeat!(agent_loop, steered, 2 * window) { |n| check_or_poll(n) }
    assert_equal "r#{steered.delete_prefix("r").to_i + (2 * window)}", key
    refused!(agent_loop, key, check)
  end

  # ── what ends the walk ───────────────────────────────────────────────

  # What re-opened the chain past a call-less answer — here a queued word the kernel plants a
  # follow-up for — was new; a stretch never spans it.
  test "a round that made no call ends the walk" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)
    same = [calls("status.txt"), [said("NOT READY")]]

    key = repeat!(agent_loop, "ask", window) { same }
    queued = loop_input!(agent_loop, acting_user: @human, text: "check once more", delivery_mode: "queue")
    assert_predicate queued, :accepted?
    run_step!(agent_loop, sse_success("still not ready"), key: key)
    assert_equal "completed", node(agent_loop, key).status, "the round answered without a call"
    schedule!(agent_loop)
    assert_equal "running", node(agent_loop, "w1").status, "the kernel planted a follow-up for the queued word"

    key = repeat!(agent_loop, "w1", window) { same }
    run_step!(agent_loop, sse_success("again", tool_calls: calls("status.txt")), key: key)
    assert_equal "completed", node(agent_loop, key).status, "the stretch before the call-less round is outside the window"
    assert_empty refusals(agent_loop)
  end

  # A pruned round's reader composed under a repair whose placeholder says to call the tool again:
  # the re-reads that follow are new by the ruling's own measure. And the brake reads ROWS: a
  # cleared result keeps its identity, so a drain's changing results stay new under the prune.
  test "a prune mark ends the walk, and rows, never the cleared placeholder, are read" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)
    prune = lambda do |continuation|
      repair = Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: continuation,
        trigger: Conversations::Compaction::Trigger.wall(continuation,
          overshoot: Conversations::Compaction::Overshoot.bytes(1)))
      assert_predicate repair, :pruned?
    end

    key = repeat!(agent_loop, "ask", window - 1) { |n| [calls("queue"), [bulky("item-#{n}")]] }
    key = round!(agent_loop, key, calls("queue"), [bulky("item-#{window}")], prepare: prune)
    key = repeat!(agent_loop, key, (2 * window) + 2) { |n| [calls("queue"), [bulky("item-#{window + 1 + n}")]] }
    assert_equal "running", node(agent_loop, key).status
    assert_empty refusals(agent_loop), "a drain under the prune arm is never refused"
  end

  test "after a prune mark a repeat is refused only once K rounds after the mark brought nothing new" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)
    same = [calls("status.txt"), [bulky("NOT READY")]]
    prune = lambda do |continuation|
      repair = Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: continuation,
        trigger: Conversations::Compaction::Trigger.wall(continuation,
          overshoot: Conversations::Compaction::Overshoot.bytes(1)))
      assert_predicate repair, :pruned?
    end

    key = repeat!(agent_loop, "ask", 4) { same }
    marked = round!(agent_loop, key, *same, prepare: prune)
    assert_predicate node(agent_loop, marked), :repaired?

    # The mark's reader asks, then K+1 more rounds expand: the first fan after the mark is new,
    # the K after it are stale, and only then is the repeat refused.
    key = repeat!(agent_loop, marked, window + 1) { same }
    assert_equal "r#{marked.delete_prefix("r").to_i + window + 1}", key
    refused!(agent_loop, key, calls("status.txt"))
  end

  test "after an arrived summary a repeat is refused only once K rounds after the mark brought nothing new" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)
    same = [calls("status.txt"), [said("NOT READY")]]
    summary_key = nil
    summarize = lambda do |continuation|
      repair = Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: continuation,
        trigger: Conversations::Compaction::Trigger.manual(user: @human))
      assert repair, "the repair arms on the continuation"
      summary_key = repair.summary_task_key
    end

    key = repeat!(agent_loop, "ask", 4) { same }
    marked = round!(agent_loop, key, *same, prepare: summarize)
    run_step!(agent_loop, sse_success("the file said NOT READY four times"), key: summary_key)
    assert_equal "running", node(agent_loop, marked).status
    assert_predicate node(agent_loop, marked).arrived_summary, :present?

    key = repeat!(agent_loop, marked, window + 1) { same }
    refused!(agent_loop, key, calls("status.txt"))
  end

  # ── what a result is ─────────────────────────────────────────────────

  # A `resource_link` carries a fresh upload id per call and `structured` is the UI's channel:
  # neither is what the model read, so neither makes a result new.
  test "links and structure are not identity" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)

    key = repeat!(agent_loop, "ask", window + 1) do |n|
      log = capture("run-#{n}.log", "line #{n}\n", "text/plain")
      [calls("suite"), [{ content: [{ "type" => "text", "text" => "3 failures" }, link(log)],
                          structured_content: { "run" => n }, creator: @human }]]
    end
    refused!(agent_loop, key, calls("suite"))
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
    agent_loop = seed(model("ask"))
    start!(agent_loop)

    key = round!(agent_loop, "ask", calls("other"), [said("elsewhere")])
    key = repeat!(agent_loop, key, window) { [calls("status.txt"), [said("NOT READY")]] }
    run_step!(agent_loop, sse_success("again", tool_calls: calls("status.txt")), key: key)
    assert_equal "completed", node(agent_loop, key).status, "the oldest judged round brought the first NOT READY"
    submit!(agent_loop, "r#{window + 2}t0", content: "NOT READY")
    schedule!(agent_loop)

    refused!(agent_loop, "r#{window + 2}", calls("status.txt"))
  end

  # The window's readers ride the kernel's log line, never a model-facing sentence: the detail
  # stays the closed word on every surface.
  test "the refusal logs the window's readers" do
    agent_loop = seed(model("ask"))
    start!(agent_loop)
    key = repeat!(agent_loop, "ask", window + 1) { [calls("status.txt"), [said("NOT READY")]] }

    lines = capture_log { refused!(agent_loop, key, calls("status.txt")) }
    logged = lines.grep(/event=agent_loop_repeat_refused/)
    assert_equal ["event=agent_loop_repeat_refused loop=#{agent_loop.public_id} task=#{key} window_first=r2 " \
                  "window_last=#{key} window=#{window} calls=1"], logged.map(&:strip)
  end
end
