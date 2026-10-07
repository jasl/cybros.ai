require "test_helper"

# THE THREAD — what a person sees. A window, never a document: a loop has no round ceiling, so every
# assertion here is about a page's cost and completeness staying independent of the loop's size —
# and about the projection reading the rows' keys, marks and reading lists, never the edge table.
# The kernel's spelling throughout: a round's calls carry its CONTINUATION's number (`r1` makes
# `r2t0`, and `r2` reads it), so the thread folds a call under the round that READ it.
class AgentRuns::TranscriptTest < ActiveJob::TestCase
  include InvocationHarness

  READ_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_file", "parameters" => { "type" => "object" } },
  }.freeze

  BASH_TOOL = {
    "type" => "function",
    "function" => { "name" => "bash", "parameters" => { "type" => "object" } },
  }.freeze

  KEY_INDEX = "index_agent_run_tasks_on_agent_run_id_and_node_key".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  # Every round declares the read tool and the three kernel doors a thread
  # folds differently: `task` (a visible branch), `ask` (a hidden await),
  # and `wait` (an existing task's result).
  def model(key, **over)
    super(key, **{ "tools" => [READ_TOOL, Nexus::Tools::DELEGATE_TASK, Nexus::Tools::ASK, Nexus::ToolRegistry.function_definition("wait")] }.merge(over))
  end

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def schedule!(agent_run)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def step_attempt(agent_run, key)
    @admitted ||= {}
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @admitted[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    clear_enqueued_jobs
    @admitted.fetch(node(agent_run, key).selected_model_invocation_id)
  end

  def run_step!(agent_run, behaviour, key:)
    apply_via(step_attempt(agent_run, key), behaviour)
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  # A round whose one call is a KERNEL tool, run in the kernel's own job.
  def kernel_round!(agent_run, key, job, name:, arguments:)
    apply_via(step_attempt(agent_run, key), sse_success("delegating", tool_calls: [
      { id: "call_k", name: name, arguments: arguments.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [job, AgentRuns::ScheduleJob]) do
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    end
    clear_enqueued_jobs
  end

  def submit!(agent_run, key, content:, is_error: false)
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: key, executor: suite_runner
    ))
    AgentRuns::Parks::Settle.call(
      node: node(agent_run, key), claim_token: claimed.value.claim_token,
      content: content, is_error: is_error, outcome: "completed"
    )
  end

  def transcript(agent_run, **over)
    AgentRuns::Transcript.call(agent_run: agent_run, **over)
  end

  def keys(result) = result.rounds.map { |row| row.fetch(:task_key) }
  def calls_of(row) = row.fetch(:calls).fetch(:items).map { |call| call.fetch(:task_key) }

  # A loop of `rounds` model rounds, each with one answered tool call.
  def run_rounds!(agent_run, rounds)
    key = "ask"
    rounds.times do |n|
      run_step!(agent_run, sse_success("round #{n}", tool_calls: [
        { id: "c#{n}", name: "read_file", arguments: "{\"path\":\"p#{n}\"}" },
      ]), key: key)
      submit!(agent_run, "r#{n + 1}t0", content: "contents #{n}")
      schedule!(agent_run)
      key = "r#{n + 1}"
    end
    key
  end

  # A WAITED `task` branch: the root `r1t0-model-1` runs, makes one call — minted `r2t0`/`r2` off
  # the loop-global counter — and its last word settles the call; then `r1`, the continuation the
  # branch was spliced under, runs.
  def waited_branch!(agent_run)
    kernel_round!(agent_run, "ask", AgentRuns::DelegateTaskToolJob, name: "delegate_task",
      arguments: { prompt: "review the diff", wait: true })
    run_step!(agent_run, sse_success("branch reading", tool_calls: [
      { id: "cb", name: "read_file", arguments: "{}" },
    ]), key: "r1t0-model-1")
    submit!(agent_run, "r2t0", content: "branch contents")
    schedule!(agent_run)
    run_step!(agent_run, sse_success("branch done"), key: "r2")
  end

  # Rows planted directly: the thread reads keys, marks and the reading
  # list, so a shape is its rows — no edge is needed to render it.
  def plant!(agent_run, rows)
    now = Time.current
    AgentRunTask.insert_all!(rows.map do |key, type, extra|
      { account_id: agent_run.account_id, agent_run_id: agent_run.id, node_key: key, type: type,
        status: "completed", authored_by: "kernel", created_at: now, updated_at: now,
        tool_name: nil, continuation_source: nil, input_from_node_keys: nil, selected_model_invocation_id: nil,
        **extra }
    end)
  end

  MODEL = AgentRunTasks::ModelTask.sti_name
  TOOL = AgentRunTasks::ToolTask.sti_name

  # A planted round carries an invocation like a real one (`@invocation`,
  # the opener's), so the page's invocation and usage batches RUN and the
  # count pins measure every statement a production page pays.
  def mainline_round(key)
    [key, MODEL, { continuation_source: "round", selected_model_invocation_id: @invocation }]
  end

  def branch_round(key, reads)
    [key, MODEL, { continuation_source: "branch", input_from_node_keys: reads, selected_model_invocation_id: @invocation }]
  end

  def call(key) = [key, TOOL, { tool_name: "read_file" }]

  # A loop whose opener ran to a plain answer: one settled invocation to
  # stamp on planted rounds, no fan to collide with planted keys.
  def opened!
    agent_run = seed(model("ask"))
    start!(agent_run)
    run_step!(agent_run, sse_success("opening"), key: "ask")
    @invocation = node(agent_run, "ask").selected_model_invocation_id
    agent_run
  end

  # ── the fold ─────────────────────────────────────────────────────────

  test "a round carries the model's own answer, and the calls it READ fold under it by the kernel's number" do
    agent_run = seed(model("ask", "prompt" => "read it"))
    start!(agent_run)
    run_rounds!(agent_run, 1)

    opener, reader = transcript(agent_run).rounds
    assert_equal "ask", opener.fetch(:task_key)
    assert_equal "Mock: round 0", opener.fetch(:text_preview)
    assert_equal({ count: 0, items: [] }, opener.fetch(:calls),
      "the opener MADE the call; the thread folds it under the round that reads it")
    assert_equal [], opener.fetch(:branches)
    assert_equal "r1", reader.fetch(:task_key)
    assert_equal 1, reader.fetch(:calls).fetch(:count)
    call = reader.fetch(:calls).fetch(:items).sole
    assert_equal %w[r1t0 read_file c0], call.values_at(:task_key, :name, :tool_call_id)
    assert_equal "contents 0", call.fetch(:output_preview),
      "the preview is stamped at write time, so this read touched no body"
    assert_equal [true, true], [opener.fetch(:mainline), reader.fetch(:mainline)],
      "the mark is the kernel's, so a client can follow the mainline"
    assert_not reader.key?(:continue), "the string of the same fact is gone"
  end

  test "the page's envelope and rows are the pack's projections, key for key and in order" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    run_rounds!(agent_run, 1)
    pack = Nexus::Contract.pack.fetch("runs.json")

    result = transcript(agent_run)
    assert_equal pack.fetch("transcript_envelope"), %w[rounds pagination]
    row_projection = pack.fetch("thread_row_projection")
    result.rounds.each do |row|
      assert_equal row_projection & row.keys.map(&:to_s), row.keys.map(&:to_s),
        "a row's keys are the projection's, in its order: #{row.keys.inspect}"
      assert_equal pack.fetch("thread_row_projection_required") - row.keys.map(&:to_s), []
      assert_equal pack.fetch("thread_calls_projection"), row.fetch(:calls).keys.map(&:to_s)
    end
    call_projection = pack.fetch("thread_call_projection")
    call = result.rounds.last.fetch(:calls).fetch(:items).sole
    assert_equal call_projection & call.keys.map(&:to_s), call.keys.map(&:to_s)
    fixture = pack.fetch("valid_thread_page_fixture")
    assert_empty fixture.fetch("rounds").flat_map(&:keys) - row_projection,
      "the hand-typed page spells only keys the row can carry"
    assert_empty fixture.fetch("rounds").flat_map { |row| row.dig("calls", "items") }.flat_map(&:keys) - call_projection
    assert_equal %w[rounds pagination], fixture.keys
  end

  # The record keeps the name the model used: `name` is the alias, `tool` the kernel's wire name,
  # present only when they differ.
  test "a call made under an alias shows the alias as its name and the kernel tool beside it" do
    agent_run = seed(model("ask", "prompt" => "delegate", "tools" => [READ_TOOL, RunLaneTestHelper::AGENT_ALIAS]))
    start!(agent_run)
    run_step!(agent_run, sse_success("delegating", tool_calls: [
      { id: "c0", name: "Agent", arguments: { prompt: "review" }.to_json },
      { id: "c1", name: "read_file", arguments: { path: "p" }.to_json },
    ]), key: "ask")

    agent, read = transcript(agent_run).rounds.last.fetch(:calls).fetch(:items)
    assert_equal %w[Agent delegate_task], agent.values_at(:name, :tool)
    assert_equal "read_file", read.fetch(:name)
    refute read.key?(:tool), "no alias, no second name"
  end

  # The sweep's word on a fan call: the row renders unrenamed with no preview — the expiry discarded
  # nothing because nothing came — and the round it belongs to renders as the round settled.
  test "a call the sweep settled uncertain renders its own word and no preview" do
    agent_run = seed(model("ask", "prompt" => "run it", "tools" => [BASH_TOOL]))
    start!(agent_run)
    run_step!(agent_run, sse_success("running", tool_calls: [
      { id: "c0", name: "bash", arguments: "{\"command\":\"x\"}" },
    ]), key: "ask")
    call = node(agent_run, "r1t0")
    assert_predicate Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: "r1t0", executor: suite_runner
    )), :accepted?
    AgentRunTask.where(id: call.id).update_all(await_started_at: 2.hours.ago)
    assert_equal 1, AgentRuns::Parks::TimeoutSweep.call[:expired]

    row = transcript(agent_run).rounds.last.fetch(:calls).fetch(:items).sole
    assert_equal "uncertain", row.fetch(:status)
    assert_not row.key?(:output_preview)
    assert_not row.key?(:is_error), "is_error is a completed call's data; an expiry has none"
    assert_equal({ key: "tool_uncertain", detail: AgentRuns::Parks::Settle::UNCERTAIN_DETAIL },
      AgentAPI::AgentRunPresenter.task_detail(call.reload)[:error],
      "the task read carries the words the transcript's row does not")
  end

  test "the window pages newest-first and returns reading order" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    run_rounds!(agent_run, 5)

    page = transcript(agent_run, limit: 2)
    assert_equal %w[r4 r5], keys(page), "the newest rounds, in reading order"
    assert page.has_older
    older = transcript(agent_run, limit: 2,
      before: AgentRunTask::TranscriptCursor.decode(page.next_before))
    assert_equal %w[r2 r3], keys(older)
    oldest = transcript(agent_run, limit: 2,
      before: AgentRunTask::TranscriptCursor.decode(older.next_before))
    assert_equal %w[ask r1], keys(oldest)
    assert_not oldest.has_older
  end

  test "one WIDE round is bounded too, and says how much it withheld" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    width = AgentRuns::Transcript::CALLS_SHOWN + 6
    run_step!(agent_run, sse_success("wide", tool_calls: (0...width).map do |n|
      { id: "c#{n}", name: "read_file", arguments: "{}" }
    end), key: "ask")

    reader = transcript(agent_run).rounds.last
    assert_equal "r1", reader.fetch(:task_key)
    assert_equal width, reader.fetch(:calls).fetch(:count)
    assert_equal AgentRuns::Transcript::CALLS_SHOWN, reader.fetch(:calls).fetch(:items).length,
      "bounding only the round COUNT would leave one wide round unrenderable; the overflow is count - items"
    assert_equal (0...AgentRuns::Transcript::CALLS_SHOWN).map { |n| "r1t#{n}" }, calls_of(reader),
      "the first of the fan, in id order"
  end

  test "the round carries what it cost, cache reuse included" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    run_step!(agent_run, sse_success("done", usage: {
      "input_tokens" => 100, "output_tokens" => 5,
      "cache_read_input_tokens" => 90, "cache_creation_input_tokens" => 10,
    }), key: "ask")

    usage = transcript(agent_run).rounds.first.fetch(:usage)
    assert_equal 90, usage.fetch(:cache_read_tokens)
    assert_equal 10, usage.fetch(:cache_creation_tokens)
  end

  # ── the branches ─────────────────────────────────────────────────────

  test "a waited task branch is a ROOT on the mainline's row, and its expansion is the branch's rounds, off the mainline" do
    agent_run = seed(model("ask", "prompt" => "delegate"))
    start!(agent_run)
    waited_branch!(agent_run)

    page = transcript(agent_run)
    assert_equal %w[ask r1], keys(page), "the branch's own rounds never reach the page"
    reader = page.rounds.last
    assert_equal ["r1t0"], calls_of(reader)
    assert_equal ["r1t0"], reader.fetch(:branches), "the call under which a visible branch hangs"
    assert_equal "completed", reader.fetch(:calls).fetch(:items).sole.fetch(:status)

    branch = transcript(agent_run, prefix: "r1t0")
    assert_equal %w[r1t0-model-1 r2], keys(branch),
      "the root by the prefix, its continuation by its FIRST READ — the loop-global key alone links nothing"
    assert_equal [false, false], branch.rounds.map { |row| row.fetch(:mainline) }
    root, continuation = branch.rounds
    assert_equal({ count: 0, items: [] }, root.fetch(:calls))
    assert_equal ["r2t0"], calls_of(continuation), "a branch round reads its own fan by the same number rule"
    assert_equal [], continuation.fetch(:branches)
    assert_equal "Mock: branch done", continuation.fetch(:text_preview)
    assert_not branch.has_older

    snapshot = AgentRuns::Transcript.round_snapshot(node(agent_run, "r1"))
    assert_equal reader, snapshot, "the settled snapshot IS the page's row: mainline, calls and branches included"
  end

  test "an explicit branch of tool-typed steps is a root with nothing to expand: the thread shows rounds" do
    agent_run = seed(model("ask", "prompt" => "expand"))
    start!(agent_run)
    kernel_round!(agent_run, "ask", nil, name: "read_file", arguments: {})
    append_branch!(node(agent_run, "r1t0"), [tool("r1t0-read", "read_file")], detached: false)

    reader = transcript(agent_run).rounds.last
    assert_equal "r1", reader.fetch(:task_key)
    assert_equal "waiting", reader.fetch(:status), "a queued round shows the calls it waits on — the thread's now"
    assert_equal ["r1t0"], calls_of(reader)
    assert_equal ["r1t0"], reader.fetch(:branches), "a visible prefixed row hangs under the call"
    assert_equal [], keys(transcript(agent_run, prefix: "r1t0")),
      "expanded tool steps are calls of no round; they show on the graph route alone"
  end

  test "the hidden matrix: plumbing, a hidden branch root, and an ask's hidden await reach neither page" do
    plumbing = seed(model("ask"), ask("gate"), model("quiet", "visibility" => "hidden"))
    start!(plumbing)
    assert_equal %w[ask], keys(transcript(plumbing)),
      "hidden is the half no client can compute; visible/collapsed are advice"

    branched = seed(model("ask", "prompt" => "delegate"))
    start!(branched)
    waited_branch!(branched)
    AgentRunTask.where(id: node(branched, "r1t0-model-1").id).update_all(transcript_visibility: "hidden")
    assert_equal [], transcript(branched).rounds.last.fetch(:branches),
      "no visible row hangs under the call once its root is hidden"
    assert_equal [], keys(transcript(branched, prefix: "r1t0")),
      "a hidden root seeds nothing, so its chain is unreachable: hidden reaches neither the window nor the feed"

    asking = seed(model("ask", "prompt" => "ask"))
    start!(asking)
    kernel_round!(asking, "ask", AgentRuns::AskJob, name: "ask", arguments: { prompt: "which database?" })
    await = node(asking, "r1t0-ask-1")
    assert_equal %w[hidden awaiting_input], [await.transcript_visibility, await.status]
    reader = transcript(asking).rounds.last
    call = reader.fetch(:calls).fetch(:items).sole
    assert_equal %w[r1t0 ask completed], call.values_at(:task_key, :name, :status),
      "the ask's face is the call row itself; the wait is the durable attention_required"
    assert_equal [], reader.fetch(:branches), "an ask is not a branch: its await is hidden"
    assert_equal [], keys(transcript(asking, prefix: "r1t0")), "the truth of a hidden row is an empty page"
  end

  # ── the two authored shapes the mock never draws ──────────────

  test "the authored halt renders its round alone: no fan, nothing branching" do
    agent_run = seed(parallel(ask("gate-1"), ask("gate-2")), model("work"))
    start!(agent_run)

    row = transcript(agent_run).rounds.sole
    assert_equal %w[work waiting], row.values_at(:task_key, :status)
    assert_equal({ count: 0, items: [] }, row.fetch(:calls), "an authored mainline key reads no `r<n>t*` fan")
    assert_equal [], row.fetch(:branches)
    assert row.fetch(:mainline), "an authored round's NULL mark is the mainline"
  end

  test "the repeat brake's refused round carries its error on its row" do
    agent_run = seed(model("ask", "tools" => [BASH_TOOL]))
    start!(agent_run)
    key = "ask"
    calls = [{ id: "c", name: "bash", arguments: { command: "cat status.txt" }.to_json }]
    window = AgentRuns::RepeatBrake::NOVELTY_WINDOW
    (window + 1).times do |round|
      run_step!(agent_run, sse_success("again", tool_calls: calls), key: key)
      submit!(agent_run, "r#{round + 1}t0", content: "NOT READY")
      schedule!(agent_run)
      key = "r#{round + 1}"
    end
    run_step!(agent_run, sse_success("again", tool_calls: calls), key: key)

    refused = transcript(agent_run).rounds.last
    assert_equal key, refused.fetch(:task_key)
    assert_equal "failed", refused.fetch(:status)
    assert_equal({ key: AgentRuns::ExpandRound::EXPANSION_REFUSED, detail: AgentRuns::RepeatBrake::REPEAT_LOOP },
      refused.fetch(:error))
    assert_equal ["#{key}t0"], calls_of(refused), "the refused round still shows what it READ"
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "r#{window + 2}t0"), "a refused expansion minted no fan"
  end

  # ── the timeline's rows ───────────────────────────────────

  test "turn_rounds batches each loop's newest MAINLINE rounds without their calls, in chain order, mark-less" do
    first = seed(model("ask", "prompt" => "read it"))
    start!(first)
    run_rounds!(first, 2)
    plant!(first, [branch_round("r9", ["r2"])])
    second = seed(model("ask"))
    start!(second)
    run_rounds!(second, 1)

    rows = AgentRuns::Transcript.turn_rounds([first, second])

    assert_equal %w[ask r1 r2], rows.fetch(first.id).map { |row| row.fetch(:task_key) },
      "a branch's round is composed work, never the turn's"
    assert_equal %w[ask r1], rows.fetch(second.id).map { |row| row.fetch(:task_key) }
    opening = rows.fetch(first.id).first
    assert_equal "Mock: round 0", opening.fetch(:text_preview)
    assert_equal "completed", opening.fetch(:status)
    %i[mainline calls branches continue].each do |word|
      assert_not opening.key?(word), "the DAG never leaks into a turn: #{word}"
    end
    assert_equal opening.keys, transcript(first).rounds.first.except(:mainline, :calls, :branches).keys,
      "ONE row shape: the loop transcript's row minus its fan and the mainline mark"
    assert_equal Nexus::Contract.pack.fetch("conversations.json").fetch("variant_round_projection"),
      opening.keys.map(&:to_s), "the pack's round row is this row"

    windowed = AgentRuns::Transcript.turn_rounds([first, second], limit: 2)
    assert_equal %w[r1 r2], windowed.fetch(first.id).map { |row| row.fetch(:task_key) },
      "the newest rounds, chronological — a page's cost never grows with the loop"
    assert_equal %w[ask r1], windowed.fetch(second.id).map { |row| row.fetch(:task_key) }
    assert_equal({}, AgentRuns::Transcript.turn_rounds([]))
  end

  # ── the cost, exact ───────────────────────────────────────────

  MAINLINE_ROUNDS = 200
  BRANCHES = 40
  WIDE_FAN = 60

  # A page costs its five statements whatever the loop holds: two hundred
  # mainline rounds, forty branches under the newest rounds' calls, one
  # sixty-wide fan, and one AUTHORED tool key inside a fan's range
  # (`r2tx`), which is a call of `r2` by the same rule.
  def plant_page_shape!(agent_run)
    rows = (1..MAINLINE_ROUNDS).flat_map { |n| [call("r#{n}t0"), mainline_round("r#{n}")] }
    rows += (1...WIDE_FAN).map { |i| call("r#{MAINLINE_ROUNDS}t#{i}") }
    (MAINLINE_ROUNDS - BRANCHES + 1..MAINLINE_ROUNDS).each_with_index do |n, index|
      rows << branch_round("r#{n}t0-model-1", nil)
      rows << branch_round("r#{MAINLINE_ROUNDS + 101 + index}", ["r#{n}t0-model-1"])
    end
    rows << call("r2tx")
    plant!(agent_run, rows)
  end

  # The page and a branch's expansion each cost exactly this many statements (pinned exact): the
  # rounds, the calls, the counts with the roots, the invocations, the usage — and the expansion one
  # more, the keyed probe that the call exists (the finder folded in from the route). Never a
  # function of the loop.
  PAGE_QUERIES = 5
  EXPANSION_QUERIES = 6

  test "a page of two hundred mainline rounds with forty branches costs exactly PAGE_QUERIES" do
    agent_run = opened!
    plant_page_shape!(agent_run)

    page = nil
    assert_queries_count(PAGE_QUERIES) { page = transcript(agent_run) }

    assert_equal (181..200).map { |n| "r#{n}" }, keys(page)
    assert page.has_older
    newest = page.rounds.last
    assert_equal [WIDE_FAN, AgentRuns::Transcript::CALLS_SHOWN], [newest.fetch(:calls).fetch(:count), calls_of(newest).length]
    assert_equal ["r200t0"], newest.fetch(:branches)
    assert page.rounds.all? { |row| row.fetch(:branches) == ["#{row.fetch(:task_key)}t0"] },
      "every round on the page has its one branch"

    oldest = transcript(agent_run, before: node(agent_run, "r3").id)
    assert_equal %w[ask r1 r2], keys(oldest)
    second = oldest.rounds.last
    assert_equal 2, second.fetch(:calls).fetch(:count)
    assert_equal %w[r2t0 r2tx], calls_of(second), "an authored key inside the range is a call of the round it names"
  end

  DEEP_BRANCH = 300
  LOOP_ROWS = 1_000

  # ONE recursive statement over the reading-list column, with no index on
  # it: O(depth × loop rows) row visits, accepted with the number — a
  # three-hundred-deep branch in a thousand-row loop answers its page in
  # EXPANSION_QUERIES and well under a second.
  test "a three-hundred-deep branch in a thousand-row loop expands in exactly EXPANSION_QUERIES, under a second" do
    agent_run = opened!
    rows = [call("r1t0"), mainline_round("r1"), branch_round("r1t0-model-1", nil)]
    previous = "r1t0-model-1"
    (2..DEEP_BRANCH + 1).each do |m|
      rows << call("r#{m}t0")
      rows << branch_round("r#{m}", [previous, "r#{m}t0"])
      previous = "r#{m}"
    end
    filler = LOOP_ROWS - rows.length - 1
    rows += (1..filler).map { |n| mainline_round("s#{n}") }
    plant!(agent_run, rows)
    assert_operator agent_run.agent_run_tasks.count, :>=, LOOP_ROWS

    page = nil
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_queries_count(EXPANSION_QUERIES) do
      page = transcript(agent_run, prefix: "r1t0", limit: AgentRuns::Transcript::MAX_LIMIT)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1.0, "the chain walk is one statement: #{elapsed.round(3)} s"
    assert_equal (202..301).map { |m| "r#{m}" }, keys(page), "the newest hundred of the branch, in reading order"
    assert page.has_older
    assert page.rounds.none? { |row| row.fetch(:mainline) }
    assert_equal ["r301t0"], calls_of(page.rounds.last)

    walked = keys(page)
    cursor = page.next_before
    while cursor
      older = transcript(agent_run, prefix: "r1t0", limit: AgentRuns::Transcript::MAX_LIMIT,
        before: AgentRunTask::TranscriptCursor.decode(cursor))
      walked = keys(older) + walked
      cursor = older.next_before
    end
    assert_equal ["r1t0-model-1", *(2..DEEP_BRANCH + 1).map { |m| "r#{m}" }], walked,
      "the branch whole, root first, every continuation by its first read"
    assert_equal [], keys(transcript(agent_run, prefix: "r1t1")), "a call with nothing under it expands to nothing"
    missing = transcript(agent_run, prefix: "r1t9")
    assert_predicate missing, :refused?
    assert_equal :task_not_found, missing.refusal, "a prefix the loop never had is the miss, not an empty branch"
    assert_equal :task_not_found, transcript(agent_run, prefix: "r1").refusal, "a round is not a call"
  end

  # ── the range, the index, the collation ───────────────────────

  # THE PLAN, in the house form (inference_request_listable_polling_plan_test): the
  # PRODUCTION statements captured as the presenter runs, explained with
  # sequential scans forbidden. What this proves is index-usability of the
  # range — the composite index serves `agent_run_id = ?` alone, and a
  # demoted range prints the same index name with the range under
  # `Filter:`, which is the failure this pin exists to catch. It cannot
  # fail on the collation defect; the two pins after it guard MEANING.
  test "the page's calls and a branch's expansion range over node_key inside the index condition" do
    # The page's shape, ANALYZEd, so the planner prices the ranges as a
    # page pays them: twenty rounds' ranges OR-ed on the calls statement,
    # a branch's range seeding the expansion. On a two-round loop the
    # planner may read the loop's rows whole and filter — the demotion
    # this pin exists to refuse at the shape a page has.
    agent_run = opened!
    plant_page_shape!(agent_run)
    ApplicationRecord.lease_connection.execute("ANALYZE agent_run_tasks")

    statements = capture_statements(/\ASELECT calls\.\*, fan\.round_key|\AWITH RECURSIVE branch/) do
      AgentRunTask.uncached do
        transcript(agent_run)
        transcript(agent_run, prefix: "r#{MAINLINE_ROUNDS}t0")
      end
    end
    assert_equal 3, statements.length,
      "the page's calls statement, the expansion statement, and the branch page's own calls statement"

    ApplicationRecord.lease_connection.execute("SET LOCAL enable_seqscan = off")
    statements.each do |sql, binds|
      plan = explain(sql, binds)
      assert_match(/(?:Index Scan using|Bitmap Index Scan on) #{KEY_INDEX}/, plan, plan)
      # The bound is a literal on the expansion's seed and a `VALUES`
      # parameter on the page's probe; either way it sits beside
      # `node_key` under `Index Cond:` and never under a `Filter:`.
      conditions = plan.scan(/Index Cond: (.*)$/).flatten
      assert conditions.any? { |condition| condition.match?(/node_key\S* >= /) && condition.match?(/node_key\S* < /) },
        "the range on node_key rides the index condition:\n#{plan}"
      plan.scan(/Filter: (.*)$/).flatten.each do |filter|
        assert_no_match(/node_key\S* [<>]=? /, filter, "the range must never be demoted to a filter:\n#{plan}")
      end
      assert_no_match(/Seq Scan on agent_run_tasks(?:\s|$)/, plan, plan)
    end
  end

  test "node_key is collated C, so a range over it means bytes on every platform" do
    collation = ApplicationRecord.lease_connection.select_value(<<~SQL.squish)
      SELECT collation_name FROM information_schema.columns
       WHERE table_name = 'agent_run_tasks' AND column_name = 'node_key'
    SQL
    assert_equal "C", collation, "the schema-loaded test database carries the migration's collation"

    agent_run = seed(model("ask"))
    plant!(agent_run, %w[r2 r2t0 r2t0-a r2t01 r2t0z r2tx r20t0 r2u].map { |key| call(key) })
    under = agent_run.agent_run_tasks.where("node_key >= ? AND node_key < ?", "r2t0-", "r2t0.").pluck(:node_key)
    assert_equal ["r2t0-a"], under, "[r2t0-, r2t0.) is exactly the keys under the call: r2t01 and r2t0z lie outside"
    fan = agent_run.agent_run_tasks.where("node_key >= ? AND node_key < ?", "r2t", "r2u").order(:node_key).pluck(:node_key)
    assert_equal %w[r2t0 r2t0-a r2t01 r2t0z r2tx], fan, "[r2t, r2u) is exactly r2's fan and what hangs under it"
  end

  private

    def capture_statements(pattern)
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        statements << [sql.dup, payload.fetch(:binds).dup] if sql.match?(pattern)
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def explain(sql, binds)
      ApplicationRecord.lease_connection.select_values("EXPLAIN #{sql}", "EXPLAIN", binds).join("\n")
    end
end
