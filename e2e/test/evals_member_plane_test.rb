require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "support/live_journey"
require "support/rate_limited"
require "socket"
require "evals_drawings"

# THE MEMBER-PLANE READS UNDER THE KERNEL'S CEILING AND THE RECEIPT RACE (evals 12a L1, L3, L7,
# L10), pinned over doubles — pure Ruby, nothing boots: a 429 is slept out for `Retry-After` and
# retried, bounded; a settled task's detail is read ONCE per (loop, key) and the trace read paces
# its uncached reads; a conversation is quiet only after two consecutive quiet polls with the same
# loop set; the runner is waited idle and a repoint refusal is the run's error at once; the
# conversation's spend after a stop sums every loop the feed named. The cost stop itself is
# `LiveJourney`'s through the shared live-journey helper (`cost_stop_harness_test.rb`).
class EvalsMemberPlaneTest < Minitest::Test
  include EvalsFixtureBench
  include E2E::LiveJourney
  include E2E::Evals::MemberPlane

  Response = Data.define(:code, :body, :headers) do
    def [](name) = headers[name]
  end

  def setup
    @unattended_bench = EvalsFixtureBench.read
    @documents = {}
    @reads = Hash.new(0)
    @slept = []
    @rows = {}
    @statuses = []
    @repoints = []
  end

  # ── the reads, doubled ───────────────────────────────────────────────
  def agent_api(path)
    @reads[path] += 1
    @documents.fetch(path)
  end

  # A scripted sequence of rows for the polls that need one per poll (the
  # unattended wait), else the one row the case pinned.
  def loop_row(loop_id) = @row_script.nil? ? @rows.fetch(loop_id) : @row_script.shift

  def loops_on_feed(_conversation) = @rows.keys

  def workspace_public_id = "ws-1"

  def pace_task_reads = (@slept << :pace)

  def summarize(row) = row.fetch("public_id")

  def read_sealed_request(*) = nil

  def feed(*) = []

  Daemon = Struct.new(:answers, :statuses) do
    def status = statuses.shift || statuses_last
    def statuses_last = { "runner" => { "in_flight" => 0 } }

    def control(_verb, _path, body:)
      answers.shift || { "root" => body[:root] }
    end
  end

  # ── L1: the 429 reader ───────────────────────────────────────────────
  def test_a_429_is_slept_out_for_retry_after_and_the_read_retried
    responses = [Response.new("429", '{"error":{"code":"rate_limited"}}', { "Retry-After" => "2" }),
                 Response.new("200", '{"task":{"key":"r1t0"}}', {})]
    _out, err = capture_io do
      document = E2E::RateLimited.read("/tasks/r1t0", sleeper: ->(s) { @slept << s }) { responses.shift }
      assert_equal({ "task" => { "key" => "r1t0" } }, document)
    end
    assert_equal [2], @slept
    assert_match(%r{/tasks/r1t0: 429 rate_limited, sleeping 2 s \(attempt 1/3\)}, err)
  end

  def test_a_429_with_no_header_sleeps_the_kernels_window_and_a_third_refusal_is_raised
    responses = [Response.new("429", "{}", {}), Response.new("429", "{}", {}), Response.new("429", "{}", {})]
    refused = nil
    capture_io do
      refused = assert_raises(E2E::RateLimited::Refused) do
        E2E::RateLimited.read("/phases", sleeper: ->(s) { @slept << s }) { responses.shift }
      end
    end
    assert_equal [60, 60], @slept, "the last refusal is raised, not slept"
    assert_match(%r{/phases: 429 rate_limited 3 times \(retry_after 60\)}, refused.message)
  end

  def test_a_200_is_parsed_on_the_first_read_with_no_sleep
    document = E2E::RateLimited.read("/x", sleeper: ->(s) { @slept << s }) { Response.new("200", '{"ok":true}', {}) }
    assert_equal({ "ok" => true }, document)
    assert_empty @slept
  end

  # ── L1: one GET per settled (loop, key); the trace read paced ────────
  def test_a_settled_tasks_detail_is_read_once_and_a_live_one_fresh
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/tasks/r1t0"] =
      { "task" => { "key" => "r1t0", "status" => "completed", "tool_input" => { "path" => "a.rb" }, "output" => "x" } }
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/tasks/r2t0"] =
      { "task" => { "key" => "r2t0", "status" => "running", "tool_input" => { "command" => "sleep" } } }
    assert_equal({ "path" => "a.rb" }, task_input("loop-1", "r1t0"))
    assert_equal "x", task_output("loop-1", "r1t0")
    assert_equal "completed", task_detail("loop-1", "r1t0")["status"]
    assert_equal 1, @reads["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/tasks/r1t0"], "three reads, one GET"
    task_detail("loop-1", "r2t0")
    task_detail("loop-1", "r2t0")
    assert_equal 2, @reads["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/tasks/r2t0"], "a live task is never memoized"
  end

  def test_the_trace_read_paces_its_uncached_task_reads_only
    @rows["loop-1"] = { "public_id" => "loop-1", "status" => "completed", "tasks" => [
      { "key" => "r1", "kind" => "model_task", "status" => "completed" },
      { "key" => "r1t0", "kind" => "tool_task", "status" => "completed", "tool_name" => "read" },
      { "key" => "r1t1", "kind" => "tool_task", "status" => "completed", "tool_name" => "read" },
    ] }
    %w[r1t0 r1t1].each do |key|
      @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/tasks/#{key}"] =
        { "task" => { "key" => key, "status" => "completed", "tool_input" => { "path" => "#{key}.rb" } } }
    end
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/tasks/r1"] = { "task" => { "key" => "r1", "status" => "completed", "request_bytes" => 900 } }
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/graph"] = { "nodes" => [], "edges" => [], "mermaid" => "" }
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/phases"] = { "spend" => { "cost_amount" => "0.1" } }
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/transcript?limit=100"] = { "rounds" => [], "pagination" => { "has_older" => false } }
    task_detail("loop-1", "r1t0")
    trace = read_trace("loop-1", nil)
    assert_equal [{ "path" => "r1t0.rb" }, { "path" => "r1t1.rb" }], trace.calls.map { |row| row["tool_input"] }
    assert_equal %i[pace pace pace], @slept, "three paced reads (the round's, one tool's, the transcript's page); the memoized one free"
    assert_equal 1, @reads["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/tasks/r1t0"]
    assert_equal 0.6, E2E::Evals::MemberPlane::TASK_READ_PACE_SECONDS, "100 reads a minute under the kernel's 120"
  end

  # ── each round's sealed bytes off its task read ───── A round's task detail carries
  # `request_bytes` (the kernel's stored size of its sealed body); the trace read joins it onto the
  # round's row through the same memoized, paced door the tool rows use — one GET per settled (loop,
  # key), so a second trace read costs no request.
  def test_the_trace_read_joins_each_rounds_sealed_bytes_off_its_task_read
    @rows["loop-1"] = { "public_id" => "loop-1", "status" => "completed", "tasks" => [
      { "key" => "r1", "kind" => "model_task", "status" => "completed" },
      { "key" => "r1t0", "kind" => "tool_task", "status" => "completed", "tool_name" => "read" },
      { "key" => "r2", "kind" => "model_task", "status" => "completed" },
    ] }
    base = "/agent_api/v1/workspaces/ws-1/agent_loops/loop-1"
    @documents["#{base}/tasks/r1"] = { "task" => { "key" => "r1", "status" => "completed", "output" => "reading", "request_bytes" => 1_200 } }
    @documents["#{base}/tasks/r1t0"] = { "task" => { "key" => "r1t0", "status" => "completed", "tool_input" => { "path" => "a.rb" } } }
    @documents["#{base}/tasks/r2"] = { "task" => { "key" => "r2", "status" => "completed", "output" => "done", "request_bytes" => 48_900 } }
    @documents["#{base}/graph"] = { "nodes" => [], "edges" => [], "mermaid" => "" }
    @documents["#{base}/phases"] = { "spend" => { "cost_amount" => "0.1" } }
    @documents["#{base}/transcript?limit=100"] = { "rounds" => [], "pagination" => { "has_older" => false } }
    trace = read_trace("loop-1", nil)
    assert_equal [1_200, 48_900], trace.rounds.map { |row| row["request_bytes"] }
    assert_equal %w[reading done], trace.rounds.map { |row| row["output"] }, "each round's own text, off the same read"
    assert_equal 0, trace.leaked_calls
    refute trace.calls.first.key?("request_bytes"), "a tool row carries none"
    assert_equal({ "r1" => 1_200, "r2" => 48_900 }, trace.efficiency.fetch("request_bytes_series"))
    assert_equal %i[pace pace pace pace], @slept, "three uncached reads and the transcript's page, each paced"
    read_trace("loop-1", nil)
    assert_equal 1, @reads["#{base}/tasks/r1"], "a settled round's detail is read once"
    assert_equal %i[pace pace pace pace pace], @slept, "the second trace read paces the transcript page alone"
  end

  # ── the spine's listings off their task reads ─────── A read-class call the SPINE made (`read`,
  # `ls`, `find`, `grep`, `glob`, `bash`) carries the text it returned — `output`, the single-task
  # read's own field, off the same memoized read — which a later brief's names are read against
  # (`Predicates.guessed_names`, D6). A branch's call and every other tool row carry their input
  # alone, so the artifact holds no text nothing reads.
  def test_the_trace_read_joins_the_spines_listing_text_alone
    base = "/agent_api/v1/workspaces/ws-1/agent_loops/loop-1"
    @rows["loop-1"] = { "public_id" => "loop-1", "status" => "completed", "tasks" => [
      { "key" => "r1", "kind" => "model_task", "status" => "completed" },
      { "key" => "r1t0", "kind" => "tool_task", "status" => "completed", "tool_name" => "ls", "after" => ["r1"] },
      { "key" => "r1t1", "kind" => "tool_task", "status" => "completed", "tool_name" => "task", "after" => ["r1"] },
      { "key" => "r2t0", "kind" => "tool_task", "status" => "completed", "tool_name" => "grep", "after" => ["r1t1-model-1"] },
    ] }
    @documents["#{base}/tasks/r1"] = { "task" => { "key" => "r1", "status" => "completed", "output" => "listing" } }
    @documents["#{base}/tasks/r1t0"] = { "task" => { "key" => "r1t0", "status" => "completed", "tool_input" => { "path" => "lib" }, "output" => "a.rb\nb.rb" } }
    @documents["#{base}/tasks/r1t1"] = { "task" => { "key" => "r1t1", "status" => "completed", "tool_input" => { "prompt" => "review" }, "output" => "done" } }
    @documents["#{base}/tasks/r2t0"] = { "task" => { "key" => "r2t0", "status" => "completed", "tool_input" => { "path" => "lib" }, "output" => "b.rb:1: def call" } }
    @documents["#{base}/graph"] = { "nodes" => [{ "key" => "r1", "kind" => "model_task", "spine" => true },
                                                { "key" => "r1t1-model-1", "kind" => "model_task", "spine" => false }], "edges" => [], "mermaid" => "" }
    @documents["#{base}/phases"] = { "spend" => { "cost_amount" => "0.1" } }
    @documents["#{base}/transcript?limit=100"] = { "rounds" => [], "pagination" => { "has_older" => false } }
    trace = read_trace("loop-1", nil)
    assert_equal({ "r1t0" => "a.rb\nb.rb", "r1t1" => nil, "r2t0" => nil }, trace.calls.to_h { |row| [row["key"], row["output"]] })
    assert_equal({ "path" => "lib" }, trace.input_of(trace.task("r1t0")), "the input rides as ever")
    refute trace.task("r1t1").key?("output"), "a task row carries no text"
  end

  # ── measured-2: each spine round's usage off ONE transcript read ─────
  # The transcript route serves every spine round's `usage` (the kernel's
  # per-round receipt: input, cache read, cache creation) newest-first
  # behind a cursor; the trace read walks it once per trace — one paced
  # GET per page of 100 — and joins the usage onto each round's row by
  # key, so the record's `cache_read_series` is `{key => [input, read]}`
  # in row order. A round the transcript does not carry (never scheduled)
  # is left out; a transcript that cannot be read is a warning and a
  # series not read, never a lost trace (the sealed request's rule).
  def test_the_trace_read_joins_each_spine_rounds_usage_off_one_paged_transcript_read
    @rows["loop-1"] = { "public_id" => "loop-1", "status" => "completed", "tasks" => [
      { "key" => "r1", "kind" => "model_task", "status" => "completed" },
      { "key" => "r2", "kind" => "model_task", "status" => "completed" },
      { "key" => "r3", "kind" => "model_task", "status" => "completed" },
      { "key" => "r4", "kind" => "model_task", "status" => "waiting" },
    ] }
    base = "/agent_api/v1/workspaces/ws-1/agent_loops/loop-1"
    %w[r1 r2 r3].each { |key| @documents["#{base}/tasks/#{key}"] = { "task" => { "key" => key, "status" => "completed", "request_bytes" => 100 } } }
    @documents["#{base}/tasks/r4"] = { "task" => { "key" => "r4", "status" => "waiting" } }
    @documents["#{base}/graph"] = { "nodes" => [], "edges" => [], "mermaid" => "" }
    @documents["#{base}/phases"] = { "spend" => { "cost_amount" => "0.1" } }
    @documents["#{base}/transcript?limit=100"] = {
      "rounds" => [{ "task_key" => "r3", "spine" => true, "usage" => { "input_tokens" => 200, "cache_read_tokens" => 3_000, "cache_creation_tokens" => 150 } }],
      "pagination" => { "next_before" => "cur-1", "has_older" => true },
    }
    @documents["#{base}/transcript?limit=100&before=cur-1"] = {
      "rounds" => [{ "task_key" => "r1", "spine" => true, "usage" => { "input_tokens" => 1_200, "cache_creation_tokens" => 1_100 } },
                   { "task_key" => "r2", "spine" => true, "usage" => { "input_tokens" => 300, "cache_read_tokens" => 1_200 } }],
      "pagination" => { "has_older" => false },
    }
    trace = read_trace("loop-1", nil)
    assert_equal({ "r1" => { "input_tokens" => 1_200, "cache_creation_tokens" => 1_100 }, "r2" => { "input_tokens" => 300, "cache_read_tokens" => 1_200 },
                   "r3" => { "input_tokens" => 200, "cache_read_tokens" => 3_000, "cache_creation_tokens" => 150 } },
      trace.rounds.first(3).to_h { |row| [row["key"], row["usage"]] })
    refute trace.rounds.last.key?("usage"), "a round never scheduled carries none"
    assert_equal({ "r1" => [1_200, 0], "r2" => [300, 1_200], "r3" => [200, 3_000] }, trace.efficiency.fetch("cache_read_series"),
      "in row order; a wire that reported no cache read on a round reads 0 there")
    assert_equal %i[pace pace pace pace pace pace], @slept, "four round reads (the waiting one too) and two transcript pages, each paced"
    assert_equal 1, @reads["#{base}/transcript?limit=100"], "one transcript walk per trace read"

    @documents.delete("#{base}/transcript?limit=100")
    _out, err = capture_io { trace = read_trace("loop-1", nil) }
    assert_match(/the transcript of loop-1 could not be read: KeyError/, err)
    assert_nil trace.efficiency.fetch("cache_read_series"), "not read, never an empty series"
    assert_equal({ "r1" => 100, "r2" => 100, "r3" => 100 }, trace.efficiency.fetch("request_bytes_series"), "the rest of the trace stands")
  end

  # ── L3: two consecutive quiet polls with the same loop set ───────────
  def test_the_conversation_is_quiet_only_after_two_quiet_polls_with_an_unchanged_loop_set
    settled = ->(id) { { "public_id" => id, "status" => "completed", "tasks" => [] } }
    running = ->(id) { { "public_id" => id, "status" => "running", "tasks" => [] } }
    # poll 1: the primary quiet; poll 2: a receipt woke loop-2 (a new set, running); poll 3, 4: both quiet.
    frames = [{ "loop-1" => settled["loop-1"] },
              { "loop-1" => settled["loop-1"], "loop-2" => running["loop-2"] },
              { "loop-1" => settled["loop-1"], "loop-2" => settled["loop-2"] },
              { "loop-1" => settled["loop-1"], "loop-2" => settled["loop-2"] }]
    polls = 0
    define_singleton_method(:loops_on_feed) do |_conversation|
      @rows = frames[[polls, frames.size - 1].min]
      polls += 1
      @rows.keys
    end
    rows = await_conversation_quiet("c-1", deadline: 60, every: 0)
    assert_equal %w[loop-1 loop-2], rows.map { |row| row["public_id"] }
    assert_equal 4, polls, "the first quiet poll did not settle it: the woken loop was seen on the second"
  end

  def test_a_quiet_poll_whose_loop_set_changed_starts_the_count_again
    settled = ->(id) { { "public_id" => id, "status" => "completed", "tasks" => [] } }
    frames = [{ "loop-1" => settled["loop-1"] }, { "loop-1" => settled["loop-1"], "loop-2" => settled["loop-2"] },
              { "loop-1" => settled["loop-1"], "loop-2" => settled["loop-2"] }]
    polls = 0
    define_singleton_method(:loops_on_feed) do |_conversation|
      @rows = frames[[polls, frames.size - 1].min]
      polls += 1
      @rows.keys
    end
    await_conversation_quiet("c-1", deadline: 60, every: 0)
    assert_equal 3, polls, "quiet, quiet-with-a-new-loop, quiet-again: the pair is polls 2 and 3"
  end

  def test_a_conversation_that_never_goes_quiet_is_the_harnesss_deadline
    @rows["loop-1"] = { "public_id" => "loop-1", "status" => "running", "tasks" => [] }
    error = assert_raises(E2E::Stopped) { await_conversation_quiet("c-1", deadline: 0, every: 0) }
    assert_equal "deadline", error.why
    assert_match(/never went quiet in 0 s: loop-1/, error.message)
  end

  # ── L7: the runner idle; the repoint; the spend after ────────────────
  def test_the_runner_is_waited_idle_before_the_repoint
    daemon = Daemon.new([], [{ "runner" => { "in_flight" => 2 } }, { "runner" => { "in_flight" => 1 } }])
    define_singleton_method(:sleep) { |_s| nil }
    assert_equal true, await_runner_idle!([daemon, nil], patience: 60)
    assert_empty daemon.statuses, "polled until the runner block read zero"
    stuck = Daemon.new([], Array.new(20) { { "runner" => { "in_flight" => 1 } } })
    _out, err = capture_io { assert_equal false, await_runner_idle!([stuck], patience: 0) }
    assert_match(/still has 1 tool call\(s\) in flight after 0 s/, err)
  end

  # The repoint is ONE call: the door answers the root or a refusal, and
  # a refusal is this run's error at once — whatever its code, the word
  # the retired 409 spelled included (ACP E1 retired the door's
  # `work_in_flight`; the runner's idle is awaited by `/status` above).
  def test_a_repoint_refusal_is_the_runs_error_at_once_and_is_never_retried
    define_singleton_method(:sleep) { |_s| flunk "a refused repoint is never slept on" }
    daemon = Daemon.new([{ "root" => "/p" }], [])
    assert_equal({ "root" => "/p" }, point_tools!(daemon, "/p"))
    refused = Daemon.new([{ "error" => { "code" => "not_a_directory" } }, { "root" => "/nowhere" }], [])
    error = assert_raises(RuntimeError) { point_tools!(refused, "/nowhere") }
    assert_match(/refused to point its tools at \/nowhere: \{"code" => "not_a_directory"\}/, error.message)
    assert_equal [{ "root" => "/nowhere" }], refused.answers, "the door was asked once"
    retired = Daemon.new([{ "error" => { "code" => "work_in_flight" } }, { "root" => "/p" }], [])
    assert_raises(RuntimeError) { point_tools!(retired, "/p") }
    assert_equal [{ "root" => "/p" }], retired.answers, "no code is a reason to ask again"
  end

  # THE REFUSAL'S SENTENCE IS THE RECORD'S: the lane files an error's FIRST line, so a `rho do` that
  # exits 1 puts its own last line (the one sentence `abort_with` prints) beside the status — the
  # v10 bench's floor runs recorded "exit 1):" alone while `provider_disabled` sat on line three.
  def test_a_failed_do_puts_its_own_sentence_on_the_errors_first_line
    status = Data.define(:ok) do
      def success? = ok
      def inspect = "#<Process::Status: pid 1 exit 1>"
    end
    output = "<internal:io>:63: warning: IO::Buffer is experimental\n" \
             "rho do: the kernel blocked the input (provider_disabled); the conversation c-1 stands\n"
    @daemon = Object.new
    @daemon.define_singleton_method(:cli) { |*_arguments| [output, status.new(ok: false)] }
    failure = assert_raises(Minitest::Assertion) { open_turn("go", "/p", model: "fixture/floor") }
    assert_equal "rho do failed (#<Process::Status: pid 1 exit 1>): " \
                 "rho do: the kernel blocked the input (provider_disabled); the conversation c-1 stands",
      failure.message.lines.first.strip
    assert_includes failure.message, "IO::Buffer is experimental", "the whole output still follows"
  end

  def test_the_spend_after_a_stop_sums_every_loop_the_feed_named
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/phases"] = { "spend" => {
      "input_tokens" => 100, "output_tokens" => 10, "cache_read_tokens" => 50, "cost_amount" => "0.10", "cost_unit" => "USD",
    } }
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-2/phases"] = { "spend" => {
      "input_tokens" => 300, "output_tokens" => 30, "cache_read_tokens" => 250, "cost_amount" => "4.19", "cost_unit" => "USD",
    } }
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-3/phases"] = { "spend" => nil }
    assert_equal({ "input_tokens" => 400, "output_tokens" => 40, "cache_read_tokens" => 300, "cache_hit_rate" => 0.75,
                   "cost_amount" => "4.29", "cost_unit" => "USD" }, spend_of_loops(%w[loop-1 loop-2 loop-3 loop-1]))
    assert_nil spend_of_loops(["loop-3"])
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-4/phases"] = { "spend" => { "input_tokens" => 0, "cost_amount" => nil, "cost_unit" => nil } }
    assert_equal({ "input_tokens" => 0, "output_tokens" => 0, "cache_read_tokens" => 0, "cache_hit_rate" => nil,
                   "cost_amount" => nil, "cost_unit" => nil }, spend_of_loops(["loop-4"]))
  end

  # THE SPLIT RIDES THE SUM: each loop's `spend.by_model` (the route's receipts grouped by the model
  # each names) is summed per model across the loops the feed named, the money a decimal String and
  # the unit one only when that model's loops agree; a sum over loops none of which served a split
  # carries none.
  def test_the_spend_after_a_stop_sums_each_models_split_across_the_loops
    opus = "alternate/strong"
    sol = "alternate/fallback"
    split = ->(input, cost) { { "input_tokens" => input, "output_tokens" => 1, "cache_read_tokens" => 0, "cost_amount" => cost, "cost_unit" => "USD" } }
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/phases"] = { "spend" => {
      "input_tokens" => 300, "output_tokens" => 2, "cache_read_tokens" => 0, "cost_amount" => "0.30", "cost_unit" => "USD",
      "by_model" => { opus => split.(100, "0.10"), sol => split.(200, "0.20") },
    } }
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-2/phases"] = { "spend" => {
      "input_tokens" => 50, "output_tokens" => 1, "cache_read_tokens" => 0, "cost_amount" => nil, "cost_unit" => nil,
      "by_model" => { sol => split.(50, nil).merge("cost_unit" => nil) },
    } }
    summed = spend_of_loops(%w[loop-1 loop-2])
    assert_equal({ opus => { "input_tokens" => 100, "output_tokens" => 1, "cache_read_tokens" => 0, "cost_amount" => "0.1", "cost_unit" => "USD" },
                   sol => { "input_tokens" => 250, "output_tokens" => 2, "cache_read_tokens" => 0, "cost_amount" => "0.2", "cost_unit" => "USD" } },
      summed["by_model"])
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-3/phases"] = { "spend" => {
      "input_tokens" => 1, "output_tokens" => 1, "cache_read_tokens" => 0, "cost_amount" => nil, "cost_unit" => nil,
    } }
    refute spend_of_loops(["loop-3"]).key?("by_model"), "no loop served a split: none is summed"
  end

  # ── the run's processes end with it ──────────────────────────────────
  # A daemon's own table as `/processes?runner=<its own runner row>` serves it — the one read that
  # relays to no followed runner — and the verbs typed at its CLI: `rho kill ID` ends the row it
  # names — the listing after it reads the row exited — unless the double is drawn stubborn, a
  # group that outlived the verb. A bare `/processes` would ask every followed host's runner through
  # Nexus, and the double refuses it; a double drawn `broken` refuses its listing.
  ProcessDaemon = Struct.new(:home, :runner, :rows, :verbs, :stubborn, :broken, keyword_init: true) do
    def status = { "identity" => { "runner_executor_public_id" => runner } }

    def control(verb, path, body: nil)
      raise ArgumentError, "unexpected #{verb} #{path} #{body.inspect}" unless verb == :get && path == "/processes?runner=#{runner}"
      raise IOError, "the control socket closed" if broken

      { "processes" => rows, "orphans" => [], "unreachable" => [] }
    end

    def cli(*argv)
      verbs << argv
      self.rows = rows.map { |row| row["id"] == argv.last && !stubborn ? row.merge("status" => "exited") : row }
      ["#{argv.last}  exited (signal TERM)", Struct.new(:success?).new(true)]
    end
  end

  def process_daemon(rows, runner: "exe-own", stubborn: false, broken: false)
    ProcessDaemon.new(home: "/tmp/home-#{runner}", runner: runner, rows: rows, verbs: [], stubborn: stubborn, broken: broken)
  end

  # THE v11 BENCH'S LEAK: a `ruby test/all.rb` a run started with `start_process` was still live
  # when the next run opened, and rho's environment sentence grew that run's developer block. Every
  # live row of each daemon's OWN table — read through its own runner row, so no followed runner's
  # table is relayed — is ended through the person's verb, `rho kill` on that daemon's CLI, and a
  # row still live after it is said out loud. A home whose listing fails is a warning naming it,
  # and the next home is still ended.
  def test_every_runs_processes_end_through_rho_kill_on_the_daemon_that_owns_them
    own = { "id" => "p-1", "status" => "running", "owner" => "c-1", "command" => "ruby test/all.rb" }
    ended = { "id" => "p-2", "status" => "exited", "owner" => "c-0", "command" => "sh serve.sh" }
    daemon = process_daemon([own, ended])
    runner = process_daemon([{ "id" => "p-4", "status" => "stopping", "owner" => "c-1", "command" => "sleep 99" }], runner: "exe-9")
    out, err = capture_io { end_processes!([daemon, nil, runner]) }
    assert_equal [%w[kill p-1]], daemon.verbs, "its own live row alone: not the exited one"
    assert_equal [%w[kill p-4]], runner.verbs, "the runner-mode home's own row, through its own CLI"
    assert_match(/^processes: 1 ended \(p-1\)$/, out)
    assert_match(/^processes: 1 ended \(p-4\)$/, out)
    assert_empty err
    quiet = process_daemon([ended])
    out, = capture_io { end_processes!([quiet]) }
    assert_empty quiet.verbs
    assert_empty out, "nothing live, nothing typed and nothing printed"
    stubborn = process_daemon([own], stubborn: true)
    _out, err = capture_io { end_processes!([stubborn]) }
    assert_match(/p-1 \(ruby test\/all\.rb\) still live after rho kill/, err)
    broken = process_daemon([own], broken: true)
    after = process_daemon([own], runner: "exe-9")
    out, err = capture_io { end_processes!([broken, after]) }
    assert_match(%r{\Athe run's processes on /tmp/home-exe-own could not be ended: IOError: the control socket closed$}, err)
    assert_equal [%w[kill p-1]], after.verbs, "a failed home never skips the next"
    assert_match(/^processes: 1 ended \(p-1\)$/, out)
  end

  # ── the member-plane client's patience ────────────────────── `Net::HTTP`'s default read timeout
  # (60 s) lost the whole trace of a loop whose phases route answered in 100–180 s; every
  # member-plane open now carries a short open and a long read, and the option reaches the client (a
  # listening socket is enough: `start` connects, nothing is sent).
  def test_the_member_plane_client_carries_the_open_and_read_timeouts
    server = TCPServer.new("127.0.0.1", 0)
    client = Object.new.extend(E2E::LiveJourney)
    timeouts = client.agent_api_http(URI("http://127.0.0.1:#{server.addr[1]}/agent_api/v1/x")) { |http| [http.open_timeout, http.read_timeout] }
    assert_equal [5, 300], timeouts
    assert_equal [E2E::LiveJourney::AGENT_API_OPEN_TIMEOUT, E2E::LiveJourney::AGENT_API_READ_TIMEOUT], timeouts
  ensure
    server&.close
  end

  # ── the unattended run's one answer (bench version 10) ───────────────
  # The plain families script no person. Before 2026-09-23 the model's own
  # `ask` ended the run at once, so a trial that would have finished was
  # filed `needs_person` while the ACP door — which has no answer to script
  # — let the same model run on. The harness now answers the BENCH's
  # sentence once and stops at the second ask, and both facts ride the
  # record so no reader mistakes the harness for a person.
  BenchPolicy = Struct.new(:per_run, :text) do
    def unattended_answers_per_run = per_run
    def unattended_answer_text = text
  end

  AnsweringDaemon = Struct.new(:calls, :ok) do
    def cli(*argv)
      calls << argv
      [ok ? "" : "no such task", Struct.new(:success?).new(ok)]
    end
  end

  def asking_row(key, loop_id: "loop-9")
    { "public_id" => loop_id, "status" => "running",
      "attention" => { "reason" => E2E::Evals::MemberPlane::ASKING_REASON },
      "tasks" => [{ "key" => key, "kind" => "await_task", "status" => "waiting",
                    "addressed_to" => { "role" => "agent_application" } }] }
  end

  def settled_row(loop_id = "loop-9") = { "public_id" => loop_id, "status" => "completed", "tasks" => [] }

  def ask!(key, prompt, loop_id: "loop-9")
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/#{loop_id}/tasks/#{key}"] =
      { "task" => { "key" => key, "status" => "waiting", "prompt" => prompt } }
  end

  # The run as its first wait finds it: the turn opened (`@conversation` as
  # `open_turn` stashes it, the stop's door), carrying what an earlier wait
  # of the same run already answered (`prior`).
  def attended!(prior: [], per_run: 1, ok: true)
    @opened = E2E::Evals::Drivers::Run.one("loop-9", "cnv-9", prior.empty? ? {} : { "harness_answered" => prior })
    @unattended_bench = BenchPolicy.new(per_run, "No person is available.")
    @daemon = AnsweringDaemon.new([], ok)
    @conversation = "cnv-9"
    @cost_stop_usd = nil
  end

  def unattended!(rows, prior: [], per_run: 1, ok: true)
    attended!(prior: prior, per_run: per_run, ok: ok)
    @row_script = rows
    await_loop_completion_unattended("loop-9", deadline: 60)
  end

  # The conversation's loops as the quiet read sees them, one frame per
  # poll, the last frame repeated.
  def quiet_frames!(frames)
    polls = 0
    define_singleton_method(:loops_on_feed) do |_conversation|
      @rows = frames[[polls, frames.size - 1].min]
      polls += 1
      @rows.keys
    end
  end

  def test_the_harness_answers_the_first_ask_with_the_benchs_sentence_and_records_both
    ask!("a1", "Which database should I use?")

    row = unattended!([asking_row("a1"), settled_row])

    assert_equal "completed", row.fetch("status")
    assert_equal [["answer", "loop-9", "a1", "No person is available."]], @daemon.calls
    answered = @opened.facts.fetch("harness_answered")
    assert_equal 1, answered.length
    assert_equal "a1", answered.first.fetch("key")
    assert_equal "loop-9", answered.first.fetch("loop"), "an ask is its loop and its key: keys repeat across loops"
    assert_equal "Which database should I use?", answered.first.fetch("prompt")
    assert_equal "No person is available.", answered.first.fetch("answer"),
      "the record says what the harness said, so no reader takes it for a person"
    assert_nil @opened.facts["asked_key"], "an answered ask is not the run's stop"
  end

  def test_a_second_ask_stops_the_run_and_the_record_keeps_the_answer_that_came_first
    ask!("a1", "first?")
    ask!("a2", "second?")

    stop = nil
    capture_io { stop = assert_raises(E2E::Stopped) { unattended!([asking_row("a1"), asking_row("a2")]) } }

    assert_equal E2E::Evals::MemberPlane::NEEDS_PERSON, stop.why
    assert_includes stop.message, "second?"
    assert_equal 1, @daemon.calls.count { |call| call.first == "answer" }, "the bench allows one answer, not one per ask"
    assert_equal ["stop", "cnv-9"], @daemon.calls.last, "the run is stopped where needs_person is raised, after the answer"
    assert_equal "a2", @opened.facts.fetch("asked_key")
    assert_equal ["a1"], @opened.facts.fetch("harness_answered").map { |row| row.fetch("key") }
  end

  def test_per_run_zero_restores_the_old_behaviour_and_answers_nothing
    ask!("a1", "anything?")

    stop = nil
    capture_io { stop = assert_raises(E2E::Stopped) { unattended!([asking_row("a1")], per_run: 0) } }

    assert_equal E2E::Evals::MemberPlane::NEEDS_PERSON, stop.why
    assert_equal [["stop", "cnv-9"]], @daemon.calls, "no answer; the stop made where needs_person is raised"
    assert_equal "a1", @opened.facts.fetch("asked_key")
  end

  # A refused answer is the harness's own failure: it raises as an error (a lane bug on the
  # record), never the model's `needs_person` stop, and never loops on the ask. The answer is
  # recorded only once the daemon took it, so the record claims nothing the model never received.
  def test_an_answer_the_daemon_refuses_is_the_harnesss_error_and_records_no_answer
    ask!("a1", "anything?")

    error = assert_raises(RuntimeError) do
      unattended!([asking_row("a1"), asking_row("a1")], ok: false)
    end

    assert_equal "the harness could not answer a1: no such task", error.message
    assert_equal 1, @daemon.calls.length
    refute @opened.facts.key?("harness_answered"), "the refused answer was never given"
    refute @opened.facts.key?("asked_key"), "the model's ask did not end the run"
  end

  # ── every wait of a run shares the one answer ────────────────────────
  # The budget is the RUN's, on the opened Run's facts: the woken turn,
  # the person's turn 2 and the quiet read each wait on their own, and a
  # budget local to one wait answered one ask per wait.
  def test_a_later_wait_reads_the_answer_an_earlier_wait_gave
    ask!("a2", "and now?")
    earlier = [{ "loop" => "loop-1", "key" => "a1", "prompt" => "first?", "answer" => "No person is available." }]

    stop = nil
    capture_io { stop = assert_raises(E2E::Stopped) { unattended!([asking_row("a2"), settled_row], prior: earlier) } }

    assert_equal E2E::Evals::MemberPlane::NEEDS_PERSON, stop.why
    assert_equal [["stop", "cnv-9"]], @daemon.calls, "the run's one answer was spent by the earlier wait: the stop alone"
    assert_equal "a2", @opened.facts.fetch("asked_key")
    assert_equal "loop-9", @opened.facts.fetch("asked_loop")
    assert_equal "and now?", @opened.facts.fetch("asked_prompt")
    assert_equal ["a1"], @opened.facts.fetch("harness_answered").map { |row| row.fetch("key") }
  end

  # The answered ask stays on the row while the answer lands: it is the
  # same ask, polled on at the wait's cadence — no second answer, no stop.
  def test_the_same_ask_seen_again_is_neither_answered_twice_nor_a_stop
    ask!("a1", "Which database should I use?")
    define_singleton_method(:sleep) { |seconds| @slept << seconds }

    row = unattended!([asking_row("a1"), asking_row("a1"), settled_row])

    assert_equal "completed", row.fetch("status")
    assert_equal [["answer", "loop-9", "a1", "No person is available."]], @daemon.calls
    assert_equal [3], @slept, "the ask still settling is polled at the loop row's cadence, never spun on"
    refute @opened.facts.key?("asked_key")
  end

  def test_the_quiet_wait_answers_a_woken_loops_ask_once
    attended!
    ask!("r3t0-ask-1", "Keep the flaky test?", loop_id: "loop-2")
    woken_asking = { "loop-1" => settled_row("loop-1"), "loop-2" => asking_row("r3t0-ask-1", loop_id: "loop-2") }
    quiet_frames!([woken_asking, woken_asking, { "loop-1" => settled_row("loop-1"), "loop-2" => settled_row("loop-2") }])

    rows = await_conversation_quiet("c-1", deadline: 60, every: 0)

    assert_equal %w[loop-1 loop-2], rows.map { |row| row.fetch("public_id") }
    assert_equal [["answer", "loop-2", "r3t0-ask-1", "No person is available."]], @daemon.calls
    assert_equal [["loop-2", "r3t0-ask-1"]], @opened.facts.fetch("harness_answered").map { |row| row.values_at("loop", "key") }
  end

  def test_a_second_ask_in_the_quiet_wait_stops_the_run_as_needs_person
    attended!
    ask!("a1", "first?", loop_id: "loop-2")
    ask!("a2", "second?", loop_id: "loop-3")
    quiet_frames!([{ "loop-1" => settled_row("loop-1"), "loop-2" => asking_row("a1", loop_id: "loop-2") },
                   { "loop-1" => settled_row("loop-1"), "loop-2" => settled_row("loop-2"),
                     "loop-3" => asking_row("a2", loop_id: "loop-3") }])

    stop = nil
    capture_io { stop = assert_raises(E2E::Stopped) { await_conversation_quiet("c-1", deadline: 5, every: 0) } }

    assert_equal E2E::Evals::MemberPlane::NEEDS_PERSON, stop.why
    assert_equal [["answer", "loop-2", "a1", "No person is available."], %w[stop cnv-9]], @daemon.calls,
      "the answer, then the stop made where needs_person is raised"
    assert_equal "loop-3", @opened.facts.fetch("asked_loop")
    assert_equal "a2", @opened.facts.fetch("asked_key")
    assert_equal "second?", @opened.facts.fetch("asked_prompt")
  end

  # A branch the model left detached keeps the loop running with its tasks
  # live; a model inside it that asks is answered from the same budget,
  # not left to raise "tasks still live" as the lane's error.
  def test_the_tasks_settled_wait_answers_an_ask_inside_a_detached_branch
    attended!
    ask!("r1t0-ask-1", "Which fixture?")
    define_singleton_method(:sleep) { |seconds| @slept << seconds }
    branch_asking = { "public_id" => "loop-9", "status" => "running",
                      "attention" => { "reason" => E2E::Evals::MemberPlane::ASKING_REASON }, "tasks" => [
                        { "key" => "r1", "kind" => "model_task", "status" => "completed" },
                        { "key" => "r1t0", "kind" => "tool_task", "status" => "completed", "tool_name" => "compose" },
                        { "key" => "r1t0-ask-1", "kind" => "await_task", "status" => "waiting",
                          "addressed_to" => { "role" => "agent_application" } },
                      ] }
    @row_script = [branch_asking, branch_asking, settled_row]

    row = await_tasks_settled("loop-9", deadline: 60)

    assert_equal "completed", row.fetch("status")
    assert_equal [["answer", "loop-9", "r1t0-ask-1", "No person is available."]], @daemon.calls
  end

  # READ BEFORE THE DEADLINE JUDGES: a wait that follows another on the same turn (turn 1's watch,
  # then its settle) passes `since:` and gets only what is left of the one deadline; with nothing
  # left the row is read once — a turn that settled as the patience ran out is settled, one still
  # running is the deadline at once, and no fresh patience is waited on.
  def test_a_wait_with_nothing_left_reads_the_row_once_before_the_deadline_judges_it
    attended!
    define_singleton_method(:sleep) { |seconds| @slept << seconds }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 61

    @row_script = [settled_row]
    assert_equal "completed", await_loop_completion_unattended("loop-9", deadline: 60, since: started).fetch("status")

    @row_script = [{ "public_id" => "loop-9", "status" => "running", "tasks" => [] }]
    stop = assert_raises(E2E::Stopped) { await_loop_completion_unattended("loop-9", deadline: 60, since: started) }
    assert_equal "deadline", stop.why
    assert_equal "the loop never settled in 60 s (0 harness answer(s))", stop.message
    assert_empty @row_script, "each wait read the row once"
    assert_empty @slept, "no patience was waited on past the shared deadline"
  end

  # ── the mail in turn 2's history ──────────────────────────────────────
  def timeline!(*turns)
    @documents["/agent_api/v1/workspaces/ws-1/conversations/c-1/turns?limit=100"] = { "turns" => turns, "pagination" => {} }
  end

  def timeline_turn(id, position, kind, origin) = { "public_id" => id, "position" => position, "kind" => kind, "origin" => origin }

  # THE RECEIPT'S OWN TURN BEFORE TURN 2: the `direct_reply` a waking receipt opened, or the
  # `message` a passive one joined the history as (every call asked `wake: "passive"`: the kernel
  # mails the receipt as history and starts no reply). A person's word before turn 2, a receipt
  # after it, or another origin's mail is not the mail turn 2 read.
  def test_the_mail_before_turn_two_is_the_receipts_own_turn_woken_or_passive
    turn_two = { "turn" => { "public_id" => "t-2" } }
    person = timeline_turn("t-1", 1, "direct_reply", "person")
    second = timeline_turn("t-2", 3, "direct_reply", "person")

    timeline!(person, timeline_turn("m-1", 2, "message", "task_result"), second)
    assert mail_before_turn?("c-1", turn_two), "a passive receipt's message turn sits in turn 2's history"
    refute mail_before_turn?("c-1", turn_two, origin: "child"), "a task's receipt is not a child's reply"

    timeline!(person, timeline_turn("w-1", 2, "direct_reply", "task_result"), second)
    assert mail_before_turn?("c-1", turn_two), "a waking receipt's own turn"

    timeline!(person, timeline_turn("m-1", 2, "message", "child"), second)
    assert mail_before_turn?("c-1", turn_two, origin: "child"), "a passive child reply"

    timeline!(person, timeline_turn("t-2", 2, "direct_reply", "person"), timeline_turn("m-1", 3, "message", "task_result"))
    refute mail_before_turn?("c-1", turn_two), "a receipt after turn 2 is not in its history"

    timeline!(person, timeline_turn("p-1", 2, "message", "person"), second)
    refute mail_before_turn?("c-1", turn_two), "a person's message is not the mail"
  end

  # ── what each composed step's request carries (the kernel check's bytes) ──
  # For every model step a compose call placed — at its top level or through a stage — its sealed
  # request off the debug door, counted over the TAIL: the entries after the last assistant entry,
  # every entry when there is none. `envelopes` counts the user entries opening `<task_result ` or
  # `<answer `, `tasks` names the task each one's opening line names, `canceled` the task of each
  # whose opening line says `status="canceled"`, `assistant` counts the assistant entries of the
  # whole request, `bytes` is the tail's entries as JSON. A composed step continues nobody, so its
  # request carries no assistant entry (`ComposedReads.check`). The spine round is never read: its
  # request is the whole history.
  BASE = "/agent_api/v1/workspaces/ws-1/agent_loops/loop-1".freeze

  def entry(role, text) = { "role" => role, "parts" => [{ "type" => "text", "text" => text }] }

  def sealed_document(entries) = { "request" => { "entries" => entries, "request_options" => {} } }

  def envelope(key, status, body) = entry("user", "<task_result task=\"#{key}\" status=\"#{status}\">\n#{body}\n</task_result>")

  def race_trace = EvalsDrawings.staged_arms([EvalsDrawings::RACE_JOIN])

  def first_step_entries
    [entry("system", "You can call several tools in one message."),
     envelope("r1t0-script-2", "completed", "{\"host\":\"bravo\"}"),
     entry("user", "<answer task=\"r1t0-ask-1\">use staging</answer>"),
     entry("user", "Name the host that answered first.")]
  end

  def test_each_composed_steps_request_is_counted_over_its_tail
    first = first_step_entries
    replayed = [*first, entry("assistant", "bravo answered first."), envelope("r1t0-script-1", "canceled", "join_loser_canceled"),
                entry("user", "Say why in one line.")]
    @documents["#{BASE}/tasks/r1t0-model-1/request"] = sealed_document(replayed)
    assert_equal({ "r1t0-model-1" => { "envelopes" => 1, "tasks" => %w[r1t0-script-1], "canceled" => %w[r1t0-script-1], "assistant" => 1,
                                       "bytes" => JSON.generate(replayed.last(2)).bytesize } },
      composed_requests("loop-1", race_trace.graph, race_trace.tasks))
    @documents["#{BASE}/tasks/r1t0-model-1/request"] = sealed_document(first)
    assert_equal({ "envelopes" => 2, "tasks" => %w[r1t0-script-2 r1t0-ask-1], "canceled" => [], "assistant" => 0,
                   "bytes" => JSON.generate(first).bytesize },
      composed_requests("loop-1", race_trace.graph, race_trace.tasks).fetch("r1t0-model-1"))
  end

  def test_no_spine_round_is_read_and_an_unsealed_request_reads_nil
    @documents["#{BASE}/tasks/r1t0-model-1/request"] = { "error" => { "code" => "request_not_sealed" } }
    assert_equal({ "r1t0-model-1" => nil }, composed_requests("loop-1", race_trace.graph, race_trace.tasks),
      "a step that never sealed a request is not read, never a lost trace")
    assert_equal 0, @reads["#{BASE}/tasks/r2/request"], "the spine round's request is the whole history"
    assert_nil composed_requests("loop-1", race_trace.graph, []), "no compose call placed a step"
  end

  # The trace read stashes the counts as the fact `composed_requests` on a run whose compose call
  # placed a model step, and reads no request on a run without one.
  def test_the_trace_read_stashes_the_composed_requests
    @rows["loop-1"] = { "public_id" => "loop-1", "status" => "completed",
                        "tasks" => [{ "key" => "r1t0", "kind" => "tool_task", "status" => "completed", "tool_name" => "compose" },
                                    race_trace.task(EvalsDrawings::RACE_JOIN)] }
    @documents["#{BASE}/tasks/r1t0"] = { "task" => { "key" => "r1t0", "status" => "completed", "tool_input" => { "script" => "x" } } }
    @documents["#{BASE}/graph"] = race_trace.graph
    @documents["#{BASE}/phases"] = { "spend" => { "cost_amount" => "0.1" } }
    @documents["#{BASE}/transcript?limit=100"] = { "rounds" => [], "pagination" => { "has_older" => false } }
    @documents["#{BASE}/tasks/r1t0-model-1/request"] = sealed_document(first_step_entries.reject { |entry| entry.dig("parts", 0, "text").start_with?("<answer") })
    trace = read_trace("loop-1", nil, facts: { reply: "bravo" })
    assert_equal 1, trace.fact(:composed_requests).dig("r1t0-model-1", "envelopes")
    assert_equal true, trace.structure_facts.fetch("kernel_check"), "the request carried what the step is owed"
    assert_equal "bravo", trace.fact(:reply), "the driver's facts ride beside it"

    @documents["#{BASE}/graph"] = { "nodes" => [], "edges" => [], "mermaid" => "" }
    reads = @reads.dup
    assert_nil read_trace("loop-1", nil).fact(:composed_requests), "no composed step, no fact"
    assert_equal reads.select { |path, _| path.end_with?("/request") }, @reads.select { |path, _| path.end_with?("/request") },
      "no request read on a run with no composed step"
  end

  # THE BENCH IS THE POLICY'S HOME, so a changed sentence is a changed
  # digest and a new column, never a blurred one.
  def test_the_supplied_bench_controls_the_unattended_answer
    bench = EvalsFixtureBench.read

    assert_equal 1, bench.unattended_answers_per_run
    assert_includes bench.unattended_answer_text, "No person is available"
    assert_equal 1, bench.version
  end
end
