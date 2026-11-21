# PARALLEL_WORKERS=1 bin/rails test test/benchmarks/run_park_sweep.rb
# EXPLAIN=1 prints park and scheduler plans. Each of OUTSIDE_RUNS unrelated
# Runs (default 2000) has 19 tasks and six held inputs. Set OUTSIDE_RUNS=12000
# to exercise the large-history scan gate. PROFILE=1 adds a pass after three warm
# samples. Timings exclude setup, dispatching jobs and model IO. SQL time
# includes adapter round trips.
# To alternate the reference sweep with the current sweep on identical rows:
#   saved=$(mktemp -d)
#   for name in schedule_sweep source_work; do
#     git show 3994bc61:nexus/app/services/runs/$name.rb > "$saved/$name.rb"
#   done
#   SCHEDULE_BASELINE_DIR="$saved" PARALLEL_WORKERS=1 bin/rails test test/benchmarks/run_park_sweep.rb -i '/schedule_recovery/'
require "test_helper"
require_relative "../test_helpers/turn_convergence_test_helper"

class RunParkSweepBenchmark < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper
  include TurnConvergenceTestHelper

  setup do
    @human = users(:owner)
    @workspace = workspaces(:shared)
  end

  test "healthy unclaimed tools sharing one executor" do
    park = start_park
    common = park.run.attributes.except("id", "public_id", "deliverable_node_id")
    hosts = Run.insert_all!(Array.new(1_000) { common }, returning: [:id]).rows.flatten
    template = park.attributes.except("id", "node_key", "run_id")
    20.times do |i|
      Task.insert_all!(hosts.map { |id| template.merge("run_id" => id, "node_key" => "read#{i}") })
    end
    ApplicationRecord.lease_connection.execute("ANALYZE runs, tasks, executors, users")

    sweep_parks
    3.times do
      sample = measure { sweep_parks }
      assert_equal [41, 20_001, 0, 0], sample.values_at(:pages, :scanned, :expired, :revoked)
      puts sample.to_json
    end
    explain_first_page if ENV["EXPLAIN"] == "1"
  end

  test "schedule recovery over 200 standalone runs waiting on a remote tool" do
    200.times { start_park }
    measure_schedule("standalone")
    assert_equal 200, Task.where(tool_name: "read_file", status: "dispatched").count
  end

  test "schedule recovery over 200 conversation runs waiting between model rounds" do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
    agent = users(:agent)
    runner = suite_runner
    declare_tools!(agent, tools: [READ_TOOL.merge("route" => {
      "kind" => "runner", "runner_executor_public_id" => runner.public_id, "tool_name" => "read_file",
    })])
    agent.update!(runner_executor_public_ids: [runner.public_id])
    200.times do
      room = Conversation.create!(workspace: @workspace, creating_user: @human,
        answering_user: agent, default_runner_executor: runner)
      _, run = materialize_loop_reply!(room, agent: agent)
      schedule_loop!(run)
      run_loop_round!(run, sse_success("Reading", tool_calls: [{ id: "read", name: "read_file", arguments: "{}" }]))
    end
    measure_schedule("conversation")
    assert_equal 200, Task.where(node_key: "r1", status: "completed").count
    assert_equal 200, Task.where(tool_name: "read_file", status: "dispatched", addressed_role: "runner").count
    assert_equal 200, Task.where(node_key: "r2", status: "queued").where("remaining_dependencies > 0").count
  end

  if ENV["EXPLAIN"] == "1"
    test "scheduler candidate plans with work outside the source page" do
      seed_running_pairs(200)
      page = Run.where(status: "running").order(:id).limit(200).ids
      # Half the inspected roots must actually follow a distinct older
      # sender. A plan whose parent join never executes can hide a full scan.
      parents, children = Run.where(id: page).joins(:variant).order(:id)
        .pluck(:public_id, "variants.turn_id").each_slice(100).to_a
      children.zip(parents).each do |(_, turn), (sender, _)|
        Turn.where(id: turn).update_all(sender_run_public_id: sender)
      end
      outside = Integer(ENV.fetch("OUTSIDE_RUNS", "2000"))
      seed_running_pairs(outside)
      others = Run.where(id: (page.last + 1)..).joins(variant: :turn)
        .pluck(:id, "turns.conversation_id", "turns.id")
      assert_equal outside, others.length
      Turn.where(id: others.map(&:last)).update_all(sender_run_public_id: Run.find(page.first).public_id)
      base = { account_id: @human.account_id, type: Tasks::ToolTask.sti_name, authored_by: "author" }
      Task.insert_all!(page.map { |id| base.merge(run_id: id, node_key: "park", status: "dispatched") })
      12.times do |i|
        Task.insert_all!(others.map { |id,| base.merge(run_id: id, node_key: "past#{i}", status: "completed") })
      end
      [
        { status: "queued" }, { status: "timed_out", on_failure: "absorb" },
        { status: "needs_approval" }, { status: "awaiting_input", type: Tasks::AwaitTask.sti_name },
        { status: "dispatched", awaited_task_key: "peer", type: Tasks::AwaitTask.sti_name },
        { status: "completed", detached: true }, { status: "running", mcp_connection_public_id: SecureRandom.uuid },
      ].each_with_index do |attributes, i|
        Task.insert_all!(others.map { |id,| base.merge(run_id: id, node_key: "work#{i}").merge(attributes) })
      end
      input = { account_id: @human.account_id, host_type: "Conversation", kind: "direct_reply", origin: "person",
        speaker_id: Speakers::Resolve.member(account: @human.account, user: @human).id, authoring_user_id: @human.id,
        answering_user_id: @human.id, state: "steering" }
      6.times do |i|
        Input.insert_all!(others.map do |_, room, turn|
          input.merge(host_id: room, steering_target_turn_id: turn, queue_position: i + 1,
            delivery_mode: i.even? ? "steer" : "steer_now")
        end)
      end
      ApplicationRecord.lease_connection.execute("ANALYZE runs, tasks, turns, variants, conversations, inputs")
      explain_schedule("skew", outside: outside)
    end
  end

  private

    def explain_schedule(shape, outside: 0)
      plans = []
      capture = ->(*, payload) do
        sql = payload.fetch(:sql)
        if payload[:name] != "SCHEMA" && sql.start_with?("SELECT", "WITH")
          plans << [sql, payload.fetch(:binds)]
        end
      end
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
        assert_equal 200, Runs::ScheduleSweep.call(result_delivery_after_id: nil).counts[:scanned]
      end
      assert_predicate plans, :present?
      plans.each do |sql, binds|
        plan = JSON.parse(ApplicationRecord.lease_connection.select_value(
          "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", "EXPLAIN", binds)).fetch(0)
        puts({ shape: shape, statement: sql.squish, plan: plan }.to_json)
        assert_page_scans(plan, outside) if outside >= 12_000
      end
    end

    # Allow planner changes and small table scans. Scanning half the
    # unrelated history to check 200 roots and 100 parents is a regression.
    def assert_page_scans(plan, outside)
      nodes = [plan.fetch("Plan")]
      until nodes.empty?
        node = nodes.pop
        nodes.concat(node.fetch("Plans", []))
        next unless %w[runs variants turns tasks inputs].include?(node["Relation Name"]) ||
          node["Node Type"] == "Bitmap Index Scan"

        count = node.fetch("Actual Rows") + node.fetch("Rows Removed by Filter", 0)
        assert_operator count * node.fetch("Actual Loops"), :<, outside / 2,
          "#{node["Node Type"]} on #{node["Relation Name"] || node["Index Name"]}"
      end
    end

    def measure_schedule(shape)
      ApplicationRecord.lease_connection.execute("ANALYZE runs, tasks, turns, variants, conversations, inputs")
      sweeps = { current: -> { Runs::ScheduleSweep.call(result_delivery_after_id: nil).counts } }
      if (directory = ENV["SCHEDULE_BASELINE_DIR"])
        # Isolate the two reference definitions. The locked owners and other
        # code are shared to measure only the changed sweep and ancestry read.
        namespace = Module.new
        owners = namespace.const_set(:Runs, Module.new)
        owners.const_set(:ScheduleReady, Runs::ScheduleReady)
        %w[source_work schedule_sweep].each { |file| load(File.join(directory, "#{file}.rb"), namespace) }
        sweeps[:baseline] = -> do
          Runs::SourceWork.stub(:stopped_source?, owners::SourceWork.method(:stopped_source?)) do
            owners::ScheduleSweep.call(result_delivery_after_id: nil).counts
          end
        end
      end
      sweeps.each_value(&:call)
      3.times do |i|
        (i.even? ? sweeps.to_a.reverse : sweeps).each do |variant, sweep|
          sample = measure(&sweep)
          assert_equal 200, sample[:scanned]
          assert_operator sample[:sql], :<, sample[:scanned] if variant == :current
          puts sample.merge(shape: shape, variant: variant, sample: i + 1).to_json
        end
      end
      if ENV["PROFILE"] == "1"
        sweeps.each do |variant, sweep|
          source = variant == :baseline ? owners::SourceWork : Runs::SourceWork
          profile_schedule(shape, variant, source, &sweep)
        end
      end
      explain_schedule(shape) if ENV["EXPLAIN"] == "1"
    end

    def start_park
      run = seed(tool("read", "read_file"), default_runner_executor_public_id: suite_runner.public_id)
      Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
      Runs::ScheduleReady.call(run_id: run.id)
      run.tasks.find_by!(node_key: "read")
    end

    def sweep_parks
      counts = { pages: 0, scanned: 0, expired: 0, revoked: 0 }
      cursor = 0
      loop do
        page = Runs::Parks::TimeoutSweep.call(after_id: cursor)
        counts[:pages] += 1
        %i[scanned expired revoked].each { |key| counts[key] += page[key] }
        break unless page.more?

        cursor = page.cursor
      end
      counts
    end

    def measure
      sql = 0
      sql_seconds = 0.0
      instantiated = 0
      queries = ActiveSupport::Notifications.monotonic_subscribe("sql.active_record") do |_, started, finished, _, payload|
        next if payload[:cached] || payload[:name] == "SCHEMA"

        sql += 1
        sql_seconds += finished - started
      end
      records = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
        instantiated += payload.fetch(:record_count)
      end
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      counts = ApplicationRecord.uncached { yield }
      ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - start
      counts.merge(sql: sql, records: instantiated, sql_ms: (sql_seconds * 1_000).round(2),
        non_sql_ms: (ms - sql_seconds * 1_000).round(2), ms: ms.round(2))
    ensure
      ActiveSupport::Notifications.unsubscribe(queries)
      ActiveSupport::Notifications.unsubscribe(records)
    end

    # Attribute each SQL event to its first application source line. Exclusive
    # owner time subtracts nested traced owners; non-SQL wall time includes
    # Active Record, application Ruby, GC and this profiling pass's overhead.
    def profile_schedule(shape, variant, source_owner)
      owners = {
        Runs::ScheduleReady => %i[call writable? schedule], Runs::Steers::Synchronize => [:call],
        Runs::SourceWork => [:with_sources], Runs::Dispatch => [:recover],
        Runs::TaskWaits => [:reconcile], Runs::Steers::Advance => [:call],
        Runs::WakeContinuation => [:call], Runs::EvaluateQuiescence => [:call],
        Conversations::Compaction::Fallback => [:call],
      }
      (owners[source_owner] ||= []) << :stopped_source?
      totals = Hash.new { |hash, owner| hash[owner] = { calls: 0, seconds: 0.0, sql_seconds: 0.0 } }
      queries = Hash.new { |hash, key| hash[key] = { calls: 0, seconds: 0.0 } }
      frames = []
      points = []
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      root = Rails.root.to_s + "/"
      app = root + "app/"
      baseline = File.expand_path(ENV.fetch("SCHEDULE_BASELINE_DIR")) + "/" if variant == :baseline
      owners.each do |owner, methods|
        methods.each do |name|
          label = "#{owner == source_owner ? Runs::SourceWork.name : owner.name}.#{name}"
          point = TracePoint.new(:call, :return) do |event|
            now = clock.call
            if event.event == :call
              totals[label][:calls] += 1
              frames << [label, now, 0.0]
            else
              _, started, children = frames.pop
              elapsed = now - started
              totals[label][:seconds] += elapsed - children
              frames.last[2] += elapsed
            end
          end
          points << point
          point.enable(target: owner.method(name), target_thread: Thread.current)
        end
      end
      subscriber = ActiveSupport::Notifications.monotonic_subscribe("sql.active_record") do |_, started, finished, _, payload|
        next if payload[:cached] || payload[:name] == "SCHEMA"

        seconds = finished - started
        label = frames.last.fetch(0)
        totals[label][:sql_seconds] += seconds
        location = caller_locations.find { |item| item.path.start_with?(app) || (baseline && item.path.start_with?(baseline)) }
        if location
          path = location.path
          path = "baseline/" + path.delete_prefix(baseline) if baseline && path.start_with?(baseline)
          source = "#{path.delete_prefix(root)}:#{location.lineno}"
        end
        statement = payload.fetch(:sql).squish
        if statement.start_with?("WITH RECURSIVE ownership")
          # This explicit SQL binds its roots via sanitize_sql_array. Keep
          # one fingerprint across Runs like the adapter's prepared queries.
          statement = statement.gsub(/(WHERE public_id = |id <> )('[\h-]{36}'|\d+)/, '\1?')
            .gsub(/WHERE id IN \([\d, ]+\)/, "WHERE id IN (?)")
        end
        row = queries[[label, source, statement]]
        row[:calls] += 1
        row[:seconds] += seconds
      end
      frames << ["Runs::ScheduleSweep", clock.call, 0.0]
      counts = ApplicationRecord.uncached { yield }
      label, started, children = frames.pop
      totals[label][:seconds] = clock.call - started - children
      totals[label][:calls] = 1
      assert_equal 200, counts[:scanned]
      totals.sort_by { |_, row| -row[:seconds] }.each do |owner, row|
        puts({ shape: shape, variant: variant, owner: owner, calls: row[:calls], sql_ms: (row[:sql_seconds] * 1_000).round(2),
          non_sql_ms: ((row[:seconds] - row[:sql_seconds]) * 1_000).round(2) }.to_json)
      end
      queries.sort_by { |_, row| -row[:seconds] }.each do |(owner, source, sql), row|
        puts({ shape: shape, variant: variant, owner: owner, source: source, statement: sql, calls: row[:calls],
          sql_ms: (row[:seconds] * 1_000).round(2) }.to_json)
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      points.each(&:disable)
    end

    def explain_first_page
      queries = []
      capture = ->(*, payload) do
        queries << [payload[:sql], payload[:binds]] if payload[:sql].include?('FROM "tasks"')
      end
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
        ApplicationRecord.uncached { Runs::Parks::TimeoutSweep.call }
      end
      queries.each do |sql, binds|
        puts sql
        puts ApplicationRecord.lease_connection.select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds)
      end
    end
end
