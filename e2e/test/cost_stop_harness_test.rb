require "test_helper"
require "evals_fixture_bench"
require "support/live_journey"
require "support/evals"
require "minitest/mock"

# THE LIVE LANES' MONEY BOUND AND THEIR REPORT LINE, pinned over doubles — nothing boots, no paid
# call: the patience is the env's word, else the bench's row for the lane's task, else the bench's
# default; the stop reads the phases route and fires over the bound — `rho stop` on the conversation
# the loop row names (the CLI door), the loop's own stop route for a standalone loop — and raises
# `E2E::Stopped` with the stop word; `watching_spend` keeps a stop that fired while a verb blocked
# and raises it once the verb returns; and the report line is built through the evals scorer's
# reader with the sealed request's BYTES, once per loop the lane awaited, at teardown, whatever the
# verdict.
class CostStopHarnessTest < Minitest::Test
  include EvalsFixtureBench
  include E2E::LiveJourney

  Status = Data.define(:ok) do
    def success? = ok
  end

  class DaemonDouble
    attr_reader :verbs

    def initialize
      @verbs = []
      @released = Queue.new
    end

    def status = { "runner" => { "swept" => 4 } }

    def cli(*arguments)
      @verbs << arguments
      case arguments.first
      when "watch" then [@released.pop.to_s, Status.new(ok: true)]
      when "stop" then (@released << "watched: stopped") && ["stopped: c-1\n", Status.new(ok: true)]
      else ["", Status.new(ok: true)]
      end
    end
  end

  class OperatorDouble
    attr_reader :enabled

    def initialize = @enabled = []

    def set_cost_unit!(_unit) = nil

    def enable_provider!(provider, key) = @enabled << [provider, key]
  end

  class HostsDouble
    def start = nil
  end

  def setup
    @daemon = DaemonDouble.new
    @documents = {}
    @posts = []
    @rows = {}
    @cost_stop_usd = 8.0
    @live_task = "harness"
    @live_model = "openrouter/acme/floor"
    @settled_loops = {}
    @reported_loops = []
  end

  # ── the reads, doubled ───────────────────────────────────────────────
  def agent_api(path) = @documents.fetch(path)

  def agent_api_post(path, body)
    @posts << [path, body]
    [{ "agent_loop" => { "status" => "stopped" } }, 200]
  end

  def loop_row(loop_id) = @rows.fetch(loop_id)

  def workspace_public_id = "ws-1"

  def spend!(loop_id, amount)
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/#{loop_id}/phases"] =
      { "spend" => { "cost_amount" => amount, "cost_unit" => "USD", "input_tokens" => 100, "output_tokens" => 10 } }
  end

  # ── the patience ─────────────────────────────────────────────────────
  def test_the_patience_is_the_envs_word_else_the_benchs_row_for_the_task_else_the_default
    bench = EvalsFixtureBench.read
    assert_equal 8.0, E2E::LiveJourney.cost_stop_usd_for("debugging", env: {}, bench: bench), "a lane the bench does not key takes the bench's default"
    assert_equal 8.0, E2E::LiveJourney.cost_stop_usd_for(nil, env: {}, bench: bench)
    assert_equal 20.0, E2E::LiveJourney.cost_stop_usd_for("exit-long", env: {}, bench: bench), "the Long lane by name, as bench.yml keys it"
    assert_equal 12.0, E2E::LiveJourney.cost_stop_usd_for("compaction-wall-long", env: {}, bench: bench)
    assert_equal 2.5, E2E::LiveJourney.cost_stop_usd_for("exit-long", env: { "E2E_LIVE_COST_STOP_USD" => "2.5" }, bench: bench),
      "the env's word wins for a run"
    assert_equal "exit_medium", E2E::LiveJourney.lane_name(Class.new { def self.name = "LiveExitMediumTest" })
    assert_equal "human_in_the_loop", E2E::LiveJourney.lane_name(Class.new { def self.name = "LiveHumanInTheLoopTest" })
  end

  def test_the_default_models_follow_the_configured_floor
    bench = EvalsFixtureBench.read
    E2E::LiveJourney.stub(:bench, bench) do
      assert_equal %w[fixture/floor fixture/exempt], E2E::LiveJourney.default_models
      assert_equal "fixture/floor", E2E::LiveJourney.default_model
    end

    changed = bench.with(document: bench.document.merge("tiers" => bench.tiers.merge("floor" => ["openrouter/acme/new-floor"])))
    E2E::LiveJourney.stub(:bench, changed) do
      assert_equal ["openrouter/acme/new-floor"], E2E::LiveJourney.default_models
      assert_equal "openrouter/acme/new-floor", E2E::LiveJourney.default_model
    end
  end

  # ONE WORLD, EVERY PROVIDER ITS MODELS NAME: the evals tier runs the broker's models and the
  # direct DeepSeek floor under one daemon, so the lane enables each provider with its own key
  # and registers each key for redaction — the first model's provider alone left every floor run
  # refused in two seconds (the v10 bench's `lane bug` rows). The key a provider is read from is
  # `ProviderLanes`' (pinned in `manual_client_harness_test.rb`).
  def test_the_lane_enables_every_provider_its_models_name_each_with_its_own_key
    models = %w[openrouter/acme/strong openrouter/acme/second deepseek/test-floor]
    operator = OperatorDouble.new
    @live_provider_keys = E2E::ProviderLanes.provider_keys_for(models)
    ENV.stub(:fetch, proc { |name, *| "harness-key-of-#{name}" }) do
      E2E.stub(:operator, operator) { E2E.stub(:hosts, HostsDouble.new) { price_and_open_lane! } }
    end
    assert_equal [%w[openrouter harness-key-of-OPENROUTER_API_KEY], %w[deepseek harness-key-of-DEEPSEEK_API_KEY]],
      operator.enabled
    assert_equal "[REDACTED] [REDACTED]",
      E2E::SecretHygiene.redact("harness-key-of-OPENROUTER_API_KEY harness-key-of-DEEPSEEK_API_KEY"),
      "every enabled key is registered for redaction"
  end

  # ── the stop ─────────────────────────────────────────────────────────
  def test_under_the_bound_nothing_is_stopped
    spend!("loop-1", "7.99")
    @rows["loop-1"] = { "public_id" => "loop-1", "status" => "running", "tasks" => [], "turn" => { "conversation_public_id" => "c-1" } }
    stop_over_cost!("loop-1")
    assert_empty @daemon.verbs
    assert_empty @posts
    @cost_stop_usd = nil
    spend!("loop-1", "900")
    stop_over_cost!("loop-1")
    assert_empty @daemon.verbs, "nil is no bound"
  end

  def test_over_the_bound_the_conversation_the_loop_row_names_is_stopped_through_the_cli_and_the_stop_raised
    spend!("loop-1", "8.25")
    @rows["loop-1"] = { "public_id" => "loop-1", "status" => "running", "tasks" => [], "turn" => { "conversation_public_id" => "c-1" } }
    error = assert_raises(E2E::Stopped) { stop_over_cost!("loop-1") }
    assert_equal "cost_stop", error.why
    assert_equal "the loop spent 8.25 over the task's 8.0: stopped", error.message
    assert_equal [["stop", "c-1"]], @daemon.verbs, "rho stop on the conversation, through the CLI door"
    assert_empty @posts
  end

  def test_a_standalone_loop_is_stopped_through_its_own_route
    spend!("loop-2", "9.00")
    @rows["loop-2"] = { "public_id" => "loop-2", "status" => "running", "tasks" => [] }
    assert_raises(E2E::Stopped) { stop_over_cost!("loop-2") }
    assert_equal [["/agent_api/v1/workspaces/ws-1/agent_loops/loop-2/stop", {}]], @posts
    assert_empty @daemon.verbs
  end

  def test_the_evals_lanes_opened_turn_wins_over_the_row
    @conversation = "c-opened"
    spend!("loop-1", "8.01")
    @rows["loop-1"] = { "public_id" => "loop-1", "status" => "running", "tasks" => [], "turn" => { "conversation_public_id" => "c-1" } }
    assert_raises(E2E::Stopped) { stop_over_cost!("loop-1") }
    assert_equal [["stop", "c-opened"]], @daemon.verbs
  end

  # ── the watch while a verb blocks ────────────────────────────────────
  def test_watching_spend_stops_a_blocking_watch_and_raises_the_stop_once_it_returns
    spend!("loop-1", "8.50")
    @rows["loop-1"] = { "public_id" => "loop-1", "status" => "running", "tasks" => [], "turn" => { "conversation_public_id" => "c-1" } }
    watched = nil
    error = assert_raises(E2E::Stopped) do
      watching_spend("loop-1", every: 0.02) { watched, = rho_watch("loop-1", "--timeout", "600") }
    end
    assert_equal "cost_stop", error.why
    assert_equal "watched: stopped", watched, "the stop released the watch"
    assert_equal ["watch", "loop-1", "--timeout", "600"], @daemon.verbs.first
    assert_includes @daemon.verbs, ["stop", "c-1"]
  end

  def test_a_watch_under_the_bound_answers_the_verb
    spend!("loop-1", "1.00")
    @rows["loop-1"] = { "public_id" => "loop-1", "status" => "running", "tasks" => [] }
    answer = watching_spend("loop-1", every: 0.02) { @daemon.cli("processes") }
    assert_equal ["", Status.new(ok: true)], answer
    assert_equal [["processes"]], @daemon.verbs
  end

  # ── the report line ──────────────────────────────────────────────────
  SEALED = { "request" => { "entries" => [{ "role" => "user", "content" => "port the codec" }], "request_options" => { "tools" => [] } } }.freeze

  def settled_row(loop_id)
    { "public_id" => loop_id, "status" => "completed", "tasks" => [
      { "key" => "r1", "kind" => "model_task", "status" => "completed" },
      { "key" => "r1t0", "kind" => "tool_task", "status" => "completed", "tool_name" => "bash", "after" => ["r1"] },
      { "key" => "r2", "kind" => "model_task", "status" => "completed" },
    ] }
  end

  def test_the_line_carries_the_spend_and_the_sealed_requests_bytes_through_the_evals_reader
    spend!("loop-1", "0.42")
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/tasks/r2/request"] = SEALED
    printed = capture_io { report_loop!(settled_row("loop-1"), seconds: 61, reached: true, succeeded: true, task_pass: false) }.first
    bytes = JSON.generate(SEALED.dig("request", "entries")).bytesize
    assert_equal "evals: harness openrouter/acme/floor nexus #1 reach=t success=t pass=f rounds=2 calls=1 " \
                 "bytes=#{bytes} bytes_max=— cost=0.42 USD cache=— compactions=— nudged=— swept=4 seconds=61\n", printed
    assert_equal ["loop-1"], @reported_loops
  end

  def test_the_teardown_prints_one_line_per_awaited_loop_not_yet_reported
    %w[loop-1 loop-2].each { |id| spend!(id, "0.10") }
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-1/tasks/r2/request"] = SEALED
    @documents["/agent_api/v1/workspaces/ws-1/agent_loops/loop-2/tasks/r2/request"] = { "error" => { "code" => "request_not_sealed" } }
    @settled_loops = { "loop-1" => { row: settled_row("loop-1"), seconds: 12.4 }, "loop-2" => { row: settled_row("loop-2"), seconds: 30.0 } }
    @reported_loops = ["loop-1"]
    printed = capture_io { report_lane! }.first
    lines = printed.lines
    assert_equal 1, lines.size, "loop-1 was reported by the lane; only loop-2 is the teardown's:\n#{printed}"
    assert_match(/\Aevals: harness openrouter\/acme\/floor nexus #2 reach=— success=— pass=— rounds=2 calls=1 bytes=— /, lines.first)
    assert_match(/ seconds=30\n\z/, lines.first)
  end

  def test_a_lane_that_prints_its_own_records_prints_no_teardown_line
    @settled_loops = { "loop-1" => { row: settled_row("loop-1"), seconds: 1.0 } }
    def self.reports_own_lines? = true
    assert_equal "", capture_io { report_lane! }.first
  end

  def test_a_report_that_cannot_be_read_warns_and_never_raises_in_a_teardown
    @settled_loops = { "loop-9" => { row: settled_row("loop-9"), seconds: 1.0 } }
    def self.report_loop!(*) = raise("the route is gone")
    _out, err = capture_io { report_lane! }
    assert_match(/the lane's report line could not be printed: RuntimeError: the route is gone/, err)
  end

  def test_await_loop_completion_remembers_the_settled_row_for_the_teardown
    @rows["loop-1"] = settled_row("loop-1")
    row = await_loop_completion("loop-1", deadline: 1)
    assert_equal "completed", row.fetch("status")
    assert_equal ["loop-1"], @settled_loops.keys
    assert_kind_of Float, @settled_loops.dig("loop-1", :seconds)
  end
end
