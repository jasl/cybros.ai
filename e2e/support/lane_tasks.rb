require "minitest/test_task"
require "rubocop/rake_task"
require "timeout"
require_relative "nexus_server"
require_relative "process_runner"
require_relative "group_run"
require_relative "world_slots"

# Each run reserves time for diagnostics and cleanup independently of product task deadlines.
# Parallel worlds use isolated databases; keep the slot count within PostgreSQL capacity.
OVERALL_DEADLINE_SECONDS = Integer(ENV.fetch("E2E_DEADLINE_SECONDS", "1800"))
TEARDOWN_DEADLINE_SECONDS = Integer(ENV.fetch("E2E_TEARDOWN_DEADLINE_SECONDS", "120"))
JOURNEY_DEADLINE_SECONDS = OVERALL_DEADLINE_SECONDS - TEARDOWN_DEADLINE_SECONDS
raise ArgumentError, "E2E_DEADLINE_SECONDS must exceed E2E_TEARDOWN_DEADLINE_SECONDS" unless JOURNEY_DEADLINE_SECONDS.positive?
# A group has its own boot, journey and teardown budget. Scheduling weights only select order;
# they never change this deadline or the kernel's task deadlines.
GROUP_DEADLINE_SECONDS = Integer(ENV.fetch("E2E_GROUP_DEADLINE_SECONDS", "1200"))
E2E::JourneyGroups.validate!

Minitest::TestTask.create(:harness_test) do |t|
  t.libs << File.expand_path("..", __dir__) << E2E::LANE_ROOT
  t.test_globs = E2E::JourneyGroups.paths(E2E::JourneyGroups::HARNESS)
end

# Keep product contracts and execution infrastructure in CI; diagnostic
# analysis and benchmark/reporting regressions stay in the full local suite.
Minitest::TestTask.create(:smoke_harness_test) do |t|
  t.libs << File.expand_path("..", __dir__) << E2E::LANE_ROOT
  t.test_globs = E2E::JourneyGroups.paths((%w[
    contract_fixtures kernel_tool_names tool_lowering_contract kernel_rule_grammar
    nexus_server_environment browser_actor_harness platform_http process_runner executor_process
    mock_llm_directives mock_llm_app mock_llm_wire_contract journey_groups group_run world_slots nexus_hosts_harness
    failure_dump_harness rho_daemon_harness install_lane_harness
  ] & E2E::JourneyGroups::HARNESS))
end

# The serial list is the union of the groups; each group is its own task,
# run in its own world by `e2e_group[k]`. Preserve the actual command and per-test timing:
# Minitest's Rake task shuffles file loading before the reported seed takes effect, so the seed
# alone cannot reproduce a run's class order.
Minitest::TestTask.create(:journey_test) do |t|
  t.libs << File.expand_path("..", __dir__) << E2E::LANE_ROOT
  t.test_globs = E2E::JourneyGroups.paths(E2E::JourneyGroups.journeys)
  t.verbose = true
  t.extra_args << "-v"
end

# Reuse whole product suites so smoke coverage follows their behavior changes.
# CI runs these in one world; the default local gate runs the ordinary journey groups.
Minitest::TestTask.create(:smoke_journey_test) do |t|
  t.libs << File.expand_path("..", __dir__) << E2E::LANE_ROOT
  t.test_globs = E2E::JourneyGroups.paths(E2E::SMOKE_JOURNEYS)
  t.verbose = true
  t.extra_args << "-v"
end

E2E::JourneyGroups::GROUPS.each do |k, files|
  Minitest::TestTask.create(:"journey_group_#{k}") do |t|
    t.libs << File.expand_path("..", __dir__) << E2E::LANE_ROOT
    t.test_globs = E2E::JourneyGroups.paths(files)
    t.verbose = true
    t.extra_args << "-v"
  end
end

Minitest::TestTask.create(:realtime_test) do |t|
  t.libs << File.expand_path("..", __dir__) << E2E::LANE_ROOT
  t.test_globs = E2E::JourneyGroups.paths(E2E::JourneyGroups::REALTIME)
  t.verbose = true
  t.extra_args << "-v"
end

RuboCop::RakeTask.new do |task|
  task.patterns = [E2E::LANE_ROOT, __dir__]
  task.options = ["--force-exclusion", "--config", File.expand_path("../.rubocop.yml", __dir__)]
end

# A lane that outlives the default names its own patience IN ITS TASK
# (`journey_seconds:`, `teardown_seconds:`): `TEARDOWN_DEADLINE_SECONDS`
# is read at load, so a task cannot raise it by setting ENV inside itself,
# and the sweep passes nothing but E2E_LIVE and E2E_LIVE_MODEL.
def run_e2e_tests(*test_tasks, journey_seconds: nil, teardown_seconds: TEARDOWN_DEADLINE_SECONDS, model_overrides: {}, mcp_fixture: false)
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  default_deadline = started_at + OVERALL_DEADLINE_SECONDS
  # THE HARNESS'S OWN PATIENCE, overridable: a long-session journey — a
  # hundred rounds against a real model — outlives the default and must be
  # able to say so without editing this file.
  journey_seconds ||= Integer(ENV.fetch("E2E_JOURNEY_SECONDS", "0"))
  journey_deadline = journey_seconds.positive? ? started_at + journey_seconds : (default_deadline - teardown_seconds)
  # A journey allowed past the default run keeps its whole teardown budget:
  # the overall deadline is never earlier than the journey's plus the
  # teardown's, or a long journey that PASSED would still fail on the drop.
  overall_deadline = [default_deadline, journey_deadline + teardown_seconds].max
  server = E2E::WORLD_CLASS.new(nexus_root: E2E::NEXUS_ROOT, model_overrides: model_overrides, mcp_fixture: mcp_fixture)
  failed = false
  primary_error = nil
  begin
    journey_remaining = journey_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise Timeout::Error, "E2E journey deadline exhausted before boot" unless journey_remaining.positive?

    Timeout.timeout(journey_remaining) do
      server.start(deadline: journey_deadline)
      status = E2E::ProcessRunner.run(
        Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "rake", *test_tasks,
        env: {
          "E2E_BASE_URL" => server.base_url,
          "E2E_NEXUS_OPERATOR" => server.operator_handle_path,
        },
        # A journey can own additional Nexus worlds. Its exit hooks need time
        # to drop those databases before the outer world's teardown begins.
        chdir: E2E::LANE_ROOT, deadline: overall_deadline, termination_timeout: teardown_seconds
      )
      raise "E2E tests failed with status #{status.exitstatus.inspect}" unless status.success?
    end
  rescue StandardError, SystemExit, SignalException => error
    # Journey failures, boot failures, and the overall deadline retain a diagnostic database dump
    # before isolated-state cleanup.
    failed = true
    primary_error = error
  ensure
    begin
      teardown_remaining = [overall_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), teardown_seconds].min
      teardown_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + [teardown_remaining, 0].max
      if teardown_remaining.positive?
        Timeout.timeout(teardown_remaining) do
          server.stop(dump: failed, deadline: teardown_deadline)
        end
      else
        server.stop(dump: failed, deadline: teardown_deadline)
      end
    rescue StandardError => cleanup_error
      if primary_error
        warn "E2E cleanup also failed: #{cleanup_error.class}: #{cleanup_error.message}"
      else
        primary_error = cleanup_error
      end
    end
  end
  raise primary_error if primary_error
end
private :run_e2e_tests

# The product E2E owns the isolated Nexus boot, readiness check, timeout, and
# teardown. Booting here keeps subprocess spawning out of the test runner's
# nested Bundler context; the tests connect through E2E_BASE_URL.
#
# `e2e` IS THE CONCURRENT RUN: the assets are built once here, then one
# `e2e_group[k]` child per group (E2E::JourneyGroups) boots its own world
# and runs `run_e2e_tests` verbatim — boot, journey, teardown and the
# dump-on-failure path are identical per world. `e2e_serial` is the one-world
# run as it was; `N=` filters there and inside a group, never here (every
# world but one would boot an empty Nexus).
desc "The ordinary product journeys, #{E2E::JourneyGroups::GROUPS.size} groups in E2E_WORLDS worlds at a time"
task :e2e do
  abort "N= filters one test: use `rake e2e_serial` or `rake \"e2e_group[k]\"`" if ENV["N"]
  open_files = Process.getrlimit(:NOFILE).first
  abort "rake e2e needs at least 1024 open files per process (`ulimit -n 4096`); the soft limit is #{open_files}" if
    open_files < 1024

  # Only a world launch needs the database's capacity. Listing tasks and running the offline
  # harness must not open a connection to the developer's Postgres.
  worlds = Integer(ENV.fetch("E2E_WORLDS") { E2E::WorldSlots.default(E2E::WorldSlots.max_connections) })
  builder = E2E::WORLD_CLASS.new(nexus_root: E2E::NEXUS_ROOT)
  begin
    builder.build_assets
  ensure
    builder.stop
  end
  groups = E2E::GroupRun.new(
    groups: E2E::JourneyGroups.spawn_order, deadline: GROUP_DEADLINE_SECONDS,
    log_dir: File.join("tmp", "e2e_groups"), slots: worlds,
    # Allow the journey's nested worlds, the outer world, and one registered
    # database-drop retry to finish before escalating an interrupted group.
    shutdown_timeout: 2 * TEARDOWN_DEADLINE_SECONDS + E2E::NexusServer::RAILS_COMMAND_TIMEOUT +
      E2E::ProcessRunner::KILL_REAP_TIMEOUT
  )
  passed = groups.run(
    command: ->(k) { [Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "rake", "e2e_group[#{k}]"] },
    chdir: E2E::LANE_ROOT
  )
  abort "e2e: a group failed (its log is named above)" unless passed
end

desc "The ordinary product journeys in one isolated world (N= filters)"
task :e2e_serial do
  run_e2e_tests("journey_test", mcp_fixture: true)
end

desc "One journey group in its own world: rake \"e2e_group[2]\" (N= filters)"
task :e2e_group, [:k] do |_t, args|
  group = Integer(args.fetch(:k))
  run_e2e_tests("journey_group_#{group}", mcp_fixture: (E2E::JourneyGroups::GROUPS.fetch(group) & %w[nexus_mcp offline_agent]).any?)
end

desc "Optional WebRTC signaling and PTY journeys (Go; some cases use Docker; N= filters)"
task :realtime do
  run_e2e_tests("realtime_test")
end

desc "Product smoke: device credentials, rho CLI conversations and a runner tool in one world"
task :smoke do
  run_e2e_tests("smoke_journey_test")
end

desc "Measure 16/32 parallel clients against an isolated Nexus (no model calls): E2E_AGENT_API_LOAD=1"
task :agent_api_load do
  abort "Set E2E_AGENT_API_LOAD=1 to run the API load measurement" unless ENV["E2E_AGENT_API_LOAD"] == "1"

  run_e2e_tests("agent_api_load_test", journey_seconds: 300)
end

Minitest::TestTask.create(:agent_api_load_test) do |t|
  t.libs << File.expand_path("..", __dir__) << E2E::LANE_ROOT
  t.test_globs = ["test/agent_api_load_test.rb"]
end

load File.join(E2E::LANE_ROOT, "tasks/diagnostics.rake") if File.file?(File.join(E2E::LANE_ROOT, "tasks/diagnostics.rake"))

# Full local acceptance: the harness, ordinary product journeys and RuboCop.
# Realtime journeys run only by name; paid diagnostics also require E2E_LIVE=1.
task default: %i[harness_test e2e rubocop]
