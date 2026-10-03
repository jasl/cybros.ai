require "test_helper"
require "fileutils"
require "json"
require "minitest/mock"
require "tmpdir"
require "support/rho_daemon"

# HOW A CHILD RHO FINDS rho-dev: the harness hands the development gem to every rho process it
# spawns — the daemon and every verb — through `RUBYLIB`, and a home that wrote no settings gets
# `{"extensions": ["rho/dev"]}` before the boot, so the conversation verbs (`do`, `say`, `watch`, …)
# the mock journeys drive are there without a line per lane. A home that wrote its own file keeps
# its own set: the product-shaped lanes say `[]` and drive `run`. The gem is never in rho's bundle,
# the installer's manifest or the images; only this harness (and a developer's shell) names its
# `lib`.
class RhoDaemonHarnessTest < Minitest::Test
  # rho-dev's verbs (`register_command` under `agents/rho/rho-dev/lib`):
  # a lane that types one through `cli(...)`, through its own `rho(...)`
  # wrapper over `cli(*args)` (rewind, skills, web_fetch, mcp_tools,
  # mcp_oauth), or through the live journeys'
  # `rho_do_turn`/`rho_watch`/`stop_conversation!` — drives a home that
  # must load the gem.
  DEV_VERBS = %w[abandon adaptations answer append approve attach btw compact conversation delete deny do
                 environment environments fetch follow graph inputs loops pause phases prompt providers regenerate
                 relay request result resume retry rewind rules say side skills stop task transcript variant
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
      assert_equal({ "extensions" => ["rho/dev"] }, JSON.parse(File.read(settings)), "a bare home names rho-dev")

      File.write(settings, JSON.generate("extensions" => [], "extension_paths" => []))
      E2E::ProcessRegistry.stub(:spawn, ->(*, **) { 4243 }) do
        started = daemon(home)
        started.stub(:await, nil) { started.start }
      end
      assert_equal({ "extensions" => [], "extension_paths" => [] }, JSON.parse(File.read(settings)),
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
      return true if statement.match?(%r{rho/dev|DEV_SETTINGS})

      statement.scan(/\b([A-Za-z_]\w*)\b/).flatten.uniq.any? do |name|
        definition = source.match(/^\s*#{Regexp.escape(name)} = /)
        definition && balanced_from(source, definition.begin(0)).match?(%r{rho/dev|DEV_SETTINGS})
      end
    end
end
