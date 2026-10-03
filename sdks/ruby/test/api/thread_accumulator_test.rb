require "test_helper"
require_relative "../support/contract_fixtures"
require_relative "../support/fake_realtime_client"

# THE LAWS OF THE LIVE THREAD, ASKED ONE AT A TIME, ON THE PACK'S BYTES:
# the page fixture seeds it, the settled
# items are the page's own rows as the kernel publishes them (a settled
# `round` IS the thread row the page serves), the three kernel frames are
# the pack's — every input typed through the shipped openers, never a hash
# written here — and the snapshot is pinned as bytes, so a client that
# reads it never re-folds.
class ThreadAccumulatorTest < Minitest::Test
  LOOP_ID = "01900000-0000-7000-8000-000000000031".freeze

  def setup
    @page = CybrosAgentTest::ContractFixtures.pack("agent_loops.json").fetch("valid_thread_page_fixture")
    @conversations = CybrosAgentTest::ContractFixtures.pack("conversations.json")
  end

  def context
    transport = CybrosAgentTest::FakeTransport.new([[200, {}, @page]])
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: transport)
      .workspace("019f0000-0000-7000-8000-000000000101").agent_loops.agent_loop(LOOP_ID)
  end

  def page = context.transcript

  def row(key) = @page.fetch("rounds").find { |round| round.fetch("task_key") == key }

  # A settled item as the kernel publishes it — `{type, keys, round|call}`
  # — through the loop's own transcript opener.
  def settled(word, snapshot)
    type = word.to_s
    frames = [{ "event" => { "type" => type, "agent_loop_public_id" => LOOP_ID,
                             "task_key" => snapshot.fetch("task_key"), type => snapshot } }]
    [].tap { |items| context.transcript(realtime: CybrosAgentTest::FakeRealtimeClient.new(frames)).call.each { |item| items << item } }.fetch(0)
  end

  def frame(word, **overrides)
    fixture = @conversations.fetch("valid_#{word}_frame_fixture")
    frames = [{ "frame" => fixture.fetch("frame").merge(overrides.transform_keys(&:to_s)) }]
    [].tap { |items| context.progress(realtime: CybrosAgentTest::FakeRealtimeClient.new(frames)).call.each { |item| items << item } }.fetch(0)
  end

  def bytes(value) = JSON.generate(value)

  def accumulator = CybrosAgent::Api::ThreadAccumulator.new

  # THE PAGE SEEDS: the rows are the page's bytes, in reading order, and
  # nothing is live until a frame says so.
  def test_a_page_seeds_the_rows_as_the_pages_own_bytes
    thread = accumulator
    thread.seed(page)

    assert_equal bytes({ "rows" => @page.fetch("rounds"), "live" => [] }), bytes(thread.snapshot)
    assert_equal %w[r1 r2 r3], thread.rows.map { |entry| entry["task_key"] }
  end

  # THE SPINE LAW: a settled round upserts its row when `spine` is true;
  # a branch's round (`spine` false) is dropped — its key is loop-global
  # and places nowhere on the thread.
  def test_a_settled_spine_round_upserts_and_a_branch_round_is_dropped
    thread = accumulator
    thread.seed(page)
    settled_tail = row("r3").merge("status" => "completed", "text_preview" => "Ran the command.", "text_bytes" => 16)

    assert_equal settled_tail, thread.settle_round(settled(:round, settled_tail))
    assert_equal bytes([row("r1"), row("r2"), settled_tail]), bytes(thread.rows), "completion replaced the page's row whole"

    branch = row("r1").merge("task_key" => "r2t1-model-1", "spine" => false)
    assert_nil thread.settle_round(settled(:round, branch))
    assert_equal bytes([row("r1"), row("r2"), settled_tail]), bytes(thread.rows), "a branch round is not the thread"
  end

  # THE NUMBER RULE ON THE KERNEL'S SPELLING (M-mf2): `r2t0` is minted
  # before `r2` runs, so a call for `r2t0` arriving before any `r2` exists
  # creates the reader's row `waiting`, and the settled `r2` then replaces it.
  def test_a_call_before_its_reader_creates_the_waiting_row_and_the_reader_settles_over_it
    thread = accumulator
    call = row("r2").dig("calls", "items", 0)

    placed = thread.settle_call(settled(:call, call))
    assert_equal bytes({ "task_key" => "r2", "spine" => true, "status" => "waiting",
                         "calls" => { "count" => 1, "items" => [call] }, "branches" => [] }), bytes(placed)
    assert_equal bytes({ "rows" => [placed], "live" => [] }), bytes(thread.snapshot)

    assert_equal row("r2"), thread.settle_round(settled(:round, row("r2")))
    assert_equal bytes([row("r2")]), bytes(thread.rows), "the reader's settled row replaced the waiting one whole"
  end

  # A call of no round — a compose member, a ladder's check — lands nowhere.
  def test_a_call_whose_key_names_no_round_is_dropped
    thread = accumulator
    assert_nil thread.settle_call(settled(:call, row("r2").dig("calls", "items", 0).merge("task_key" => "r2t0-lint")))
    assert_nil thread.settle_call(settled(:call, row("r2").dig("calls", "items", 0).merge("task_key" => "check-1")))
    assert_empty thread.rows
  end

  # LIVENESS: `round_started` marks the row running with the attempt, the
  # model and the sealed size; `step_started` upserts the call's live
  # status (held, then dispatched — both news, one entry); `step_claimed`
  # names the claimant on it. `live` is what is running, by key.
  def test_frames_mark_liveness_on_the_row_and_the_call_they_name
    thread = accumulator
    thread.seed(page)

    started = thread.round_started(frame(:round_started))
    assert_equal bytes(row("r3").merge("status" => "running", "attempt" => 1, "model" => "dev/mock-text",
                                       "request_bytes" => 41_208)), bytes(started)
    assert_equal ["r3"], thread.live

    held = thread.step_started(frame(:step_started, status: "needs_approval"))
    assert_equal bytes({ "task_key" => "r4", "spine" => true, "status" => "waiting",
                         "calls" => { "count" => 1, "items" => [{ "task_key" => "r4t0", "name" => "read_file", "status" => "needs_approval" }] },
                         "branches" => [] }), bytes(held), "a call before its reader: the row is born waiting"
    dispatched = thread.step_started(frame(:step_started))
    assert_equal [{ "task_key" => "r4t0", "name" => "read_file", "status" => "dispatched" }], dispatched.dig("calls", "items"),
      "the second start upserts the status; nothing is appended"
    claimed = thread.step_claimed(frame(:step_claimed))
    assert_equal [{ "task_key" => "r4t0", "name" => "read_file", "status" => "dispatched",
                    "executor_public_id" => "01900000-0000-7000-8000-000000000030" }], claimed.dig("calls", "items")
    assert_equal %w[r3 r4t0], thread.live
    assert_equal %w[r1 r2 r3 r4], thread.rows.map { |entry| entry["task_key"] }
  end

  # COMPLETION WINS: the settled snapshot replaces the live mark, whole —
  # the call's claimant goes with its settle, the round's attempt with its.
  def test_the_settled_snapshot_replaces_the_live_mark
    thread = accumulator
    thread.seed(page)
    thread.round_started(frame(:round_started))
    thread.step_started(frame(:step_started))
    thread.step_claimed(frame(:step_claimed))

    settled_call = row("r2").dig("calls", "items", 0).merge("task_key" => "r4t0")
    thread.settle_call(settled(:call, settled_call))
    assert_equal ["r3"], thread.live
    assert_equal [settled_call], thread.rows.last.dig("calls", "items"), "the claimant went with the settle"

    settled_round = row("r3").merge("status" => "completed", "text_preview" => "Ran the command.", "text_bytes" => 16)
    thread.settle_round(settled(:round, settled_round))
    assert_empty thread.live
    assert_equal bytes(settled_round), bytes(thread.rows.fetch(2)), "no attempt, no model, no size: the snapshot is whole"
  end

  # THE GUESS A KEY FORCES, AND ITS RETRACTION: a branch round's calls
  # spell `r<n>t<i>` like the spine's, so the row born from one is a guess
  # until the reader speaks — a `round_started` with `spine` false retracts
  # it, and nothing under that number lands again.
  def test_a_branch_rounds_guessed_row_is_retracted_when_its_reader_says_branch
    thread = accumulator
    thread.seed(page)
    thread.step_started(frame(:step_started))
    assert_equal %w[r1 r2 r3 r4], thread.rows.map { |entry| entry["task_key"] }

    assert_nil thread.round_started(frame(:round_started, task_key: "r4", spine: false))
    assert_equal %w[r1 r2 r3], thread.rows.map { |entry| entry["task_key"] }, "the guess is gone"
    assert_empty thread.live
    assert_nil thread.settle_call(settled(:call, row("r2").dig("calls", "items", 0).merge("task_key" => "r4t1")))
    assert_nil thread.step_started(frame(:step_started, task_key: "r4t1"))
    assert_equal %w[r1 r2 r3], thread.rows.map { |entry| entry["task_key"] }, "nothing under a branch's number lands"
  end

  # A page re-read is the truth again: the marks and the branch memory go.
  def test_a_new_page_replaces_everything_held
    thread = accumulator
    thread.round_started(frame(:round_started))
    thread.round_started(frame(:round_started, task_key: "r4", spine: false))
    thread.seed(page)

    assert_equal bytes({ "rows" => @page.fetch("rounds"), "live" => [] }), bytes(thread.snapshot)
    assert_equal "r4", thread.step_started(frame(:step_started)).fetch("task_key"), "a page forgets what it guessed"
  end

  # THE DAEMON'S RELAY IS THE SAME SHAPE: an item's `to_h` (the JSON rho's
  # SSE carries) folds exactly as the typed object does, so rho never
  # re-folds and never re-types.
  def test_the_wire_hash_of_an_item_or_a_frame_folds_as_the_typed_object_does
    typed = accumulator
    relayed = accumulator
    settled_row = row("r3").merge("status" => "completed")

    [typed, relayed].each { |thread| thread.seed(page) }
    typed.round_started(frame(:round_started))
    relayed.round_started(JSON.parse(bytes(frame(:round_started).to_h)))
    typed.settle_round(settled(:round, settled_row))
    relayed.settle_round(JSON.parse(bytes(settled(:round, settled_row).to_h)))

    assert_equal bytes(typed.snapshot), bytes(relayed.snapshot)
    assert_equal bytes({ "rows" => [row("r1"), row("r2"), settled_row], "live" => [] }), bytes(relayed.snapshot)
  end
end
