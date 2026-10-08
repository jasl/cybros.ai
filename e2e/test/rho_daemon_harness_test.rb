require "test_helper"
require "fileutils"
require "json"
require "minitest/mock"
require "tmpdir"
require "support/rho_daemon"

# HOW A CHILD RHO FINDS rho-dev: the harness hands the development gem to every rho process it
# spawns — the daemon and every verb — through `RUBYLIB`, and a home that wrote no settings gets
# a current settings document enabling rho.dev before boot, so the conversation verbs (`do`, `say`, `watch`, …)
# the mock journeys drive are there without a line per lane. A home that wrote its own file keeps
# its own set: product-shaped lanes omit rho.dev and drive `run`. The gem is never in rho's bundle,
# the installer's manifest or the images; only this harness (and a developer's shell) names its
# `lib`.
class RhoDaemonHarnessTest < Minitest::Test
  # rho-dev's verbs (`register_command` under `agents/rho/rho-dev/lib`):
  # a lane that types one through `cli(...)`, through its own `rho(...)`
  # wrapper over `cli(*args)` (rewind, skills, web_fetch, mcp_tools,
  # mcp_oauth), or through the live journeys'
  # `rho_do_turn`/`rho_watch`/`stop_conversation!` — drives a home that
  # must load the gem.
  DEV_VERBS = %w[abandon adaptations answer append approve attach compact conversation delete deny do
                 environment environments fetch follow graph inputs loops pause phases prompt providers regenerate
                 relay request result resume retry rewind rules say side skills stop delegate_task transcript variant
                 watch].freeze
  DEV_CALL = /\b(?:cli|cli_background|rho)\("(?:#{DEV_VERBS.join("|")})"|\brho_do_turn\(|\brho_watch\(|\bstop_conversation!\(/
  # The two spellings a lane writes a daemon home's settings in: the file
  # by its path, or the live journeys' `write_daemon_home!`. A RUNNER-MODE
  # home (`@runner_home`) serves no conversation verb and names no dev.
  SETTINGS_WRITE = /File\.write\(File\.join\((?!@runner_home)[^,]+, "settings\.json"\)|write_daemon_home!\(settings:/
  LANES = Dir[File.expand_path("*_test.rb", __dir__)].sort.freeze
  BRACKETS = { "(" => 1, "[" => 1, "{" => 1, ")" => -1, "]" => -1, "}" => -1 }.freeze

  def daemon(home) = E2E::RhoDaemon.new(base_url: "http://127.0.0.1:1", home: home)

  def test_the_childs_rubylib_starts_with_rho_devs_lib
    Dir.mktmpdir("rho-dev-harness") do |home|
      env = daemon(home).send(:child_env)
      rubylib = env.fetch("RUBYLIB").split(File::PATH_SEPARATOR)
      assert_equal E2E::RhoDaemon::RHO_DEV_LIB, rubylib.first, "the gem's lib leads the child's load path"
      assert File.file?(File.join(E2E::RhoDaemon::RHO_DEV_LIB, "rho", "dev.rb")), "the loader's leg: require \"rho/dev\""
      assert_equal E2E::RhoDaemon::CHILD_BUNDLE_ENV.fetch("BUNDLE_FROZEN"), env.fetch("BUNDLE_FROZEN"),
        "the bundle pins stand beside it"
    end
  end

  # `start` writes the dev settings FIRST, on a bare home only; a home
  # that wrote its own file (the product-shaped lanes' `[]`, an extension
  # lane's own set) is never touched.
  def test_start_writes_the_dev_settings_on_a_bare_home_and_nothing_on_a_written_one
    Dir.mktmpdir("rho-dev-harness") do |home|
      settings = File.join(home, "settings.json")
      spawned = []
      E2E::ProcessRegistry.stub(:spawn, ->(*arguments, **) { spawned << arguments; 4242 }) do
        started = daemon(home)
        started.stub(:await, nil) { started.start }
      end
      assert_equal 1, spawned.length, "the daemon was spawned"
      assert_equal E2E::RhoDaemon::DEV_SETTINGS, JSON.parse(File.read(settings)), "a bare home names rho-dev"
      assert_equal 0o600, File.stat(settings).mode & 0o777, "settings use the credential-bearing document's private mode"

      File.write(settings, JSON.generate("settings_version" => 1, "plugins" => {}), perm: 0o600)
      E2E::ProcessRegistry.stub(:spawn, ->(*, **) { 4243 }) do
        started = daemon(home)
        started.stub(:await, nil) { started.start }
      end
      assert_equal({ "settings_version" => 1, "plugins" => {} }, JSON.parse(File.read(settings)),
        "a home that wrote its own file keeps it")
    end
  end

  def test_start_ceremony_waits_for_bootstrap_and_spends_the_device_budget_once
    started = daemon(Dir.tmpdir)
    bootstrapping = { "error" => { "code" => "connection_bootstrapping" } }
    pending = { "phase" => "pending", "branch" => "combined", "user_code" => "ABCD-EFGH" }
    responses = [bootstrapping, bootstrapping, pending]
    requests = []
    waits = []
    consumed = 0
    request = ->(verb, path) { requests << [verb, path]; responses.fetch(requests.length - 1) }

    E2E::DeviceAuthorizationBudget.stub(:consume, -> { consumed += 1 }) do
      started.stub(:control, request) do
        started.stub(:sleep, ->(seconds) { waits << seconds }) do
          assert_same pending, started.start_ceremony
        end
      end
    end

    assert_equal [[:post, "/device/start"]] * 3, requests
    assert_equal [E2E::RhoDaemon::POLL] * 2, waits
    assert_equal 1, consumed
  end

  def test_final_disposal_disconnects_after_stopping_and_preserves_the_cli_outcome
    Dir.mktmpdir("rho-disposal-harness") do |home|
      pointer = File.join(home, "connection.json")
      File.write(pointer, "{}")
      started = daemon(home)
      outcome = ["disconnect failed", :failed_status]
      calls = []
      E2E::ProcessRegistry.stub(:spawn, ->(*, **) { 4242 }) do
        started.stub(:await, nil) { started.start }
      end
      E2E::ProcessRegistry.stub(:terminate, ->(pid) { calls << [:stop, pid] }) do
        started.stub(:cli, ->(*arguments) { calls << arguments; outcome }) do
          started.stop
          assert File.file?(pointer), "a restart keeps the connection"
          assert_empty calls.drop(1), "ordinary stop never disconnects"
          E2E::ProcessRegistry.stub(:spawn, ->(*, **) { 4243 }) do
            started.stub(:await, nil) { started.start }
          end
          assert_same outcome, started.dispose_connection
        end
      end
      assert_equal [[:stop, 4242], [:stop, 4243], ["disconnect"]], calls
    end
  end

  def test_final_disposal_skips_a_home_without_a_connection
    Dir.mktmpdir("rho-disposal-harness") do |home|
      started = daemon(home)
      started.stub(:cli, ->(*) { flunk "a fresh or already disconnected home has no lineage" }) do
        assert_nil started.dispose_connection
      end
    end
  end

  def test_final_disposal_waits_out_repeated_revocation_throttling
    Dir.mktmpdir("rho-disposal-harness") do |home|
      File.write(File.join(home, "connection.json"), "{}")
      started = daemon(home)
      completed = ["disconnected", :success_status]
      outcomes = [revocation_throttled] * 4 + [completed]
      calls = []
      waits = []
      now = 0
      command = lambda do |*arguments|
        calls << arguments
        now += 1
        outcomes.shift
      end
      sleeper = ->(seconds) { waits << seconds; now += seconds }

      Process.stub(:clock_gettime, ->(*) { now }) do
        started.stub(:sleep, sleeper) do
          started.stub(:cli, command) { assert_same completed, started.dispose_connection }
        end
      end

      assert_equal [["disconnect"]] * 5, calls
      assert_equal [5] * 4, waits
      assert_empty outcomes
    end
  end

  def test_final_disposal_counts_cli_runtime_in_its_retry_deadline
    Dir.mktmpdir("rho-disposal-harness") do |home|
      File.write(File.join(home, "connection.json"), "{}")
      started = daemon(home)
      refused = revocation_throttled
      calls = 0
      waits = []
      now = 0
      command = lambda do |*|
        calls += 1
        now += calls == 1 ? 1 : 51
        refused
      end
      sleeper = ->(seconds) { waits << seconds; now += seconds }

      Process.stub(:clock_gettime, ->(*) { now }) do
        started.stub(:sleep, sleeper) do
          started.stub(:cli, command) { assert_same refused, started.dispose_connection }
        end
      end

      assert_equal 2, calls
      assert_equal [5], waits
    end
  end

  def test_final_disposal_does_not_restart_the_cli_when_the_wait_outlasts_its_deadline
    Dir.mktmpdir("rho-disposal-harness") do |home|
      File.write(File.join(home, "connection.json"), "{}")
      started = daemon(home)
      refused = revocation_throttled
      calls = 0
      waits = []
      now = 0
      sleeper = ->(seconds) { waits << seconds; now += 61 }

      Process.stub(:clock_gettime, ->(*) { now }) do
        started.stub(:sleep, sleeper) do
          started.stub(:cli, ->(*) { calls += 1; refused }) do
            assert_same refused, started.dispose_connection
          end
        end
      end

      assert_equal 1, calls
      assert_equal [5], waits
    end
  end

  def test_start_ceremony_does_not_retry_another_refusal_or_a_transport_failure
    started = daemon(Dir.tmpdir)
    refused = { "error" => { "code" => "connection_failed" } }
    failure = Errno::ECONNRESET.new("the ceremony response was lost")
    E2E::DeviceAuthorizationBudget.stub(:consume, nil) do
      started.stub(:sleep, ->(*) { flunk "only bootstrapping may be waited for" }) do
        started.stub(:control, refused) { assert_same refused, started.start_ceremony }
        started.stub(:control, ->(*) { raise failure }) do
          assert_same failure, assert_raises(Errno::ECONNRESET) { started.start_ceremony }
        end
      end
    end
  end

  def test_start_ceremony_bootstrap_wait_keeps_one_readiness_deadline
    started = daemon(Dir.tmpdir)
    bootstrapping = { "error" => { "code" => "connection_bootstrapping" } }
    times = [0, E2E::RhoDaemon::READY_TIMEOUT - 0.1, E2E::RhoDaemon::READY_TIMEOUT + 0.1]
    requests = 0
    waits = []
    E2E::DeviceAuthorizationBudget.stub(:consume, nil) do
      started.stub(:control, ->(*) { requests += 1; bootstrapping }) do
        started.stub(:sleep, ->(seconds) { waits << seconds }) do
          Process.stub(:clock_gettime, ->(*) { times.shift }) do
            error = assert_raises(RuntimeError) { started.start_ceremony }
            assert_equal "the daemon never finished bootstrapping its connection", error.message
          end
        end
      end
    end

    assert_equal 2, requests
    assert_equal [E2E::RhoDaemon::POLL], waits
    assert_empty times
  end

  # THE SELF-WRITING HOMES: the fixture never merges — a file that exists is the lane's own word —
  # so a lane that writes its own `settings.json` AND types a dev verb must name `rho/dev` in what
  # it writes. A file carrying `adaptations` or `compaction` alone loses the verbs silently, and the
  # miss shows only in a paid window as `Could not find command "do"` (the 2026-09-17 gate:
  # rho_conversation ×3, delegate_compaction). Read off every lane's source, one settings write at a
  # time; a constant or local the write names (`SETTINGS`, `settings`) is resolved to its definition
  # in the same file. `E2E::RhoDaemon::DEV_SETTINGS.merge(...)` is the spelling.
  def test_every_lane_that_types_a_dev_verb_names_rho_dev_in_the_settings_it_writes
    offenders = LANES.flat_map do |path|
      source = File.read(path, encoding: Encoding::UTF_8)
      next [] unless source.match?(DEV_CALL)

      settings_writes(source).reject { |statement| names_dev?(statement, source) }
        .map { |statement| "#{File.basename(path)}: #{statement.lines.first.strip}" }
    end
    assert_empty offenders,
      "a home that types a dev verb wrote settings without `rho/dev` " \
      "(spell it `E2E::RhoDaemon::DEV_SETTINGS.merge(...)`):\n#{offenders.join("\n")}"
  end

  private

    def revocation_throttled
      error = CybrosAgent::DeviceFlow::RateLimited.new(retry_after: 5)
      ["rho disconnect: #{error.message}\n", :failed_status]
    end

    # Every settings-write statement in a lane, whole: from the write to
    # the line its brackets balance on.
    def settings_writes(source)
      source.enum_for(:scan, SETTINGS_WRITE).map { balanced_from(source, Regexp.last_match.begin(0)) }
    end

    # The statement starting at `start`, read to the end of the first line
    # on which every bracket opened since is closed.
    def balanced_from(source, start)
      depth = 0
      index = start
      while index < source.length
        depth += BRACKETS.fetch(source[index], 0)
        return source[start..index] if source[index] == "\n" && depth <= 0

        index += 1
      end
      source[start..]
    end

    # `rho/dev` in the statement itself, or in the definition of a name
    # the statement passes (`JSON.generate(SETTINGS)`, `pretty_generate(settings)`).
    def names_dev?(statement, source)
      return true if statement.match?(%r{rho/dev|DEV_SETTINGS|dev_settings})

      statement.scan(/\b([A-Za-z_]\w*)\b/).flatten.uniq.any? do |name|
        definition = source.match(/^\s*#{Regexp.escape(name)} = /)
        definition && balanced_from(source, definition.begin(0)).match?(%r{rho/dev|DEV_SETTINGS|dev_settings})
      end
    end
end
