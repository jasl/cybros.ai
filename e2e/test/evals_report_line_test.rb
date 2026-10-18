require "test_helper"
require "evals_fixture_bench"
require "support/evals"

# THE ONE REPORT LINE PER PAID RUN, PINNED: a pure formatter over the record — every field in order,
# a `—` where nothing was read and `0` where something was read and there was none, the compaction
# tally in parentheses, the stop word and the class on the tail — and `lane`, the record a graded
# live lane builds off its own reads so the four lanes and the evals print through ONE
# implementation.
class EvalsReportLineTest < Minitest::Test
  include EvalsFixtureBench
  D = E2E::Evals::Drawing
  L = E2E::Evals::ReportLine

  def test_the_line_carries_every_field_in_order
    record = D.record(seconds: 61, efficiency: {
      "rounds" => 4, "calls" => 3, "request_bytes" => 12_345, "request_bytes_series" => { "r1" => 900, "r2" => 20_000, "r3" => 4_000, "r4" => 12_345 },
      "cost_amount" => 0.0312, "cost_unit" => "USD", "cache_read_tokens" => 8_000, "cache_hit_rate" => 0.8125,
      "cache_read_series" => { "r1" => [900, 450], "r2" => [2_000, 1_800], "r3" => [3_000, 2_900], "r4" => [4_000, 2_850] },
      "compactions" => { "kernel/wall" => 1, "prune/wall" => 2 }, "compactions_survived" => 3, "nudged" => nil, "swept" => 7,
    })
    assert_equal "evals: shape-linear fixture/strong nexus #1 reach=t success=t pass=t rounds=4 calls=3 " \
                 "bytes=12345 bytes_max=20000 cost=0.0312 USD cache=0.8389 (r1=0.5 total=0.8125) compactions=3 (kernel/wall×1 prune/wall×2) nudged=— swept=7 seconds=61",
      L.render(record)
  end

  # THE CACHE FIELD IS THE RATE AFTER ROUND 1: `cache=<rounds 2..n pooled>` — the headline number,
  # `—` when the record carries no per-round series or one round alone — then, in parentheses, the
  # two facts beside it when read: `r1=<the first round's rate>` (the provider's cross-run prefix,
  # recorded, never gated) and `total=<the loop's rate off the progress spend>` (the cost term,
  # every loop pooled); nothing in parentheses when neither was read.
  def test_the_cache_field_prints_the_rate_after_round_1_with_r1_and_the_total_beside_it
    assert_equal "cache=— (total=0.5)", L.render(D.record(efficiency: { "cache_hit_rate" => 0.5 }))[/cache=\S+( \([^)]*\))?/]
    assert_equal "cache=— (r1=0.0 total=0.5)",
      L.render(D.record(efficiency: { "cache_hit_rate" => 0.5, "cache_read_series" => { "r1" => [100, 0] } }))[/cache=\S+( \([^)]*\))?/]
    assert_equal "cache=—", L.render(D.record(efficiency: { "cache_read_series" => { "r1" => [0, 0] } }))[/cache=\S+( \([^)]*\))?/]
    assert_equal "cache=0.8889 (r1=0.8333 total=0.9)",
      L.render(D.record(efficiency: { "cache_hit_rate" => 0.9, "cache_read_series" => { "r1" => [600, 500], "r2" => [900, 800] } }))[/cache=\S+( \([^)]*\))?/]
    assert_equal "cache=0.0 (r1=0.0)",
      L.render(D.record(efficiency: { "cache_read_series" => { "r1" => [600, 0], "r2" => [900, 0] } }))[/cache=\S+( \([^)]*\))?/], "read, none"
  end

  def test_a_dash_is_not_read_and_a_zero_is_read_and_none
    record = D.record(reached: false, succeeded: nil, task_pass: nil, seconds: nil,
      efficiency: { "rounds" => 0, "calls" => 0, "compactions" => {} })
    assert_equal "evals: shape-linear fixture/strong nexus #1 reach=f success=— pass=— rounds=0 calls=0 " \
                 "bytes=— bytes_max=— cost=— cache=— compactions=0 nudged=— swept=— seconds=—", L.render(record)
    assert_equal "compactions=—", L.render(D.record(efficiency: {}))[/compactions=\S+/]
    # A series read with no round in it (no round completed) is the dash too: there is no max of nothing.
    assert_equal "bytes_max=—", L.render(D.record(efficiency: { "request_bytes_series" => {} }))[/bytes_max=\S+/]
  end

  def test_the_tail_names_the_stop_and_the_class
    stopped = D.record(stopped: "cost_stop", verdict: { "reached" => true, "succeeded" => false, "task_pass" => nil, "class" => "model conduct" })
    assert_match(/seconds=60 stopped=cost_stop \[model conduct\]\z/, L.render(stopped))
    assert_match(/seconds=60 \[kernel finding\]\z/, L.render(D.record(verdict: { "reached" => true, "class" => "kernel finding" })))
    assert_match(/seconds=60 \[disagreement\]\z/, L.render(D.record(verdict: { "reached" => true, "class" => E2E::Evals::Scorecard::DISAGREEMENT })))
    assert_match(/seconds=60 \[cache under floor\]\z/, L.render(D.record(verdict: { "reached" => true, "class" => E2E::Evals::Scorecard::CACHE_UNDER_FLOOR })))
    assert_match(/seconds=60 stopped=interrupted \[lane bug\]\z/,
      L.render(D.record(stopped: "interrupted", verdict: { "reached" => true, "class" => "lane bug" })))
    refute_match(/stopped=/, L.render(D.record))
  end

  # THE FALLBACK'S TOKEN: a record whose refused steps the answerer's declared fallback served
  # prints `fb=<served>` ahead of the stop and the class — a fact on a green line — and a record
  # with none served, or from before the fact, prints nothing.
  def test_the_tail_names_the_steps_the_fallback_served
    facts = { "round_errors" => {}, "attention_reasons" => {}, "rounds_settled" => 3 }
    assert_match(/seconds=60 fb=2\z/, L.render(D.record(facts: facts.merge("refusals_served" => 2))))
    assert_match(/seconds=60 fb=1 stopped=deadline \[model conduct\]\z/,
      L.render(D.record(stopped: "deadline", facts: facts.merge("refusals_served" => 1),
        verdict: { "reached" => true, "class" => "model conduct" })))
    refute_match(/fb=/, L.render(D.record(facts: facts.merge("refusals_served" => 0, "model_switches" => 1))))
    refute_match(/fb=/, L.render(D.record))
  end

  # A LIVE LANE'S RECORD: the loop row's tasks count the rounds and calls,
  # the feed's items the compactions, the sealed request the bytes, the
  # runner meter the sweeps; the verdict columns are the lane's own.
  def test_lane_builds_a_record_off_a_lanes_reads
    row = { "public_id" => "loop-9", "status" => "completed", "tasks" => [
      D.round("r1"), D.tool("r1t0", "write", after: ["r1"]), D.round("r2"), D.tool("r2t0", "bash", after: ["r2"]), D.round("r3"),
    ] }
    events = [D.event("context_compacted", { "mode" => "prune", "trigger" => "wall" })]
    sealed = { "task_key" => "r3", "entries" => [{ "role" => "user", "content" => "hi" }], "request_options" => { "tools" => [] } }
    record = L.lane(task: "exit-medium", model: "fixture/second", row: row, events: events,
      spend: { "cost_amount" => 0.5, "cost_unit" => "USD", "input_tokens" => 10, "output_tokens" => 2,
               "cache_read_tokens" => 5, "cache_hit_rate" => 0.5 },
      sealed: sealed, seconds: 120, reached: true, succeeded: true, task_pass: false, swept: 3)
    assert_equal "exit-medium", record["task"]
    assert_equal({ "reached" => true, "succeeded" => true, "task_pass" => false, "class" => nil }, record["verdict"])
    assert_equal 3, record.dig("efficiency", "rounds")
    assert_equal 2, record.dig("efficiency", "calls")
    assert_equal JSON.generate(sealed["entries"]).bytesize, record.dig("efficiency", "request_bytes")
    assert_equal({ "prune/wall" => 1 }, record.dig("efficiency", "compactions"))
    assert_equal 3, record.dig("efficiency", "swept")
    assert_nil record.dig("efficiency", "nudged")
    assert_equal 5, record.dig("efficiency", "cache_read_tokens")
    assert_equal 0.5, record.dig("efficiency", "cache_hit_rate")
    assert_nil record.dig("efficiency", "request_bytes_series"), "a lane reads no round detail: the series is not read"
    assert_nil record.dig("efficiency", "cache_read_series"), "nor the per-round usage"
    assert_equal "evals: exit-medium fixture/second nexus #1 reach=t success=t pass=f rounds=3 calls=2 " \
                 "bytes=#{record.dig("efficiency", "request_bytes")} bytes_max=— cost=0.5 USD cache=— (total=0.5) compactions=1 (prune/wall×1) nudged=— swept=3 seconds=120",
      L.render(record)
  end

  def test_lane_with_no_row_prints_its_dashes
    record = L.lane(task: "shape-halt-retry", model: "m", row: nil, seconds: 5, succeeded: false)
    assert_equal({}, record["efficiency"])
    assert_equal "evals: shape-halt-retry m nexus #1 reach=— success=f pass=— rounds=— calls=— bytes=— bytes_max=— cost=— cache=— " \
                 "compactions=— nudged=— swept=— seconds=5", L.render(record)
  end
end
