require "test_helper"
require "support/evals/harbor_acp"
require "support/evals/ledger"
require "rho/version"
require "date"
require "fileutils"
require "json"
require "open3"
require "socket"
require "stringio"
require "tmpdir"

# THE HARBOR CELL'S HARNESS, PINNED WITHOUT A WORLD OR DOCKER: the registry entry read off the gem's
# own file, its `local` distribution the cell's (the launcher in the image, with the three env names
# the launcher reads), the plan off the terminal-bench fixture (the cell's model and k from
# bench.yml's `terminal_bench` block, a stranger refused by name, the label dated, the tags the
# plain driver's) and the command line spelled once; the launcher parsed with `bash -n` and its ruby
# door driven against a fake daemon (no announcement, a dead endpoint, pending, the bootstrapping
# window, the pairing document written whole, adopted); the pairing sidecar over a fake `docker
# ps`/`docker exec` — every running container by id, one confirm per container, a document with no
# code never confirmed, a container with no file never paired, the URLs rewritten for the steward's
# browser; and the import of a job dir into the ledger's records shape — one record per trial, the
# reward as `task_pass`, no reach, harbor's own errors a lane bug — read back through `Ledger`; and
# the OVERLAY CORPUS harbor reads (the fixture's task copied onto its derived tag: the files as they
# are, `docker_image` gone from task.toml, `environment/Dockerfile` FROM the tag with tini alone in
# front of harbor's command, written under the job dir before harbor is spawned).
class HarborAcpTest < Minitest::Test
  H = E2E::Evals::HarborAcp
  K = E2E::Evals::Docker
  T = E2E::Evals::TerminalBench
  FIXTURE = File.expand_path("../support/fixtures/terminal_bench", __dir__)
  REAL = E2E::Evals::Bench.read
  BENCH = REAL.with(document: REAL.document.merge("terminal_bench" => REAL.terminal_bench.merge("tasks" => %w[alpha-one beta-two])))
  POLICY = T::Policy.of(BENCH)
  FLOOR = POLICY.cell_models.first
  TODAY = Date.new(2026, 9, 18)
  Status = Data.define(:ok) do
    def success? = ok
  end
  OK = Status.new(ok: true)
  NO = Status.new(ok: false)

  def corpus = @corpus ||= T.load(FIXTURE, bench: BENCH)

  def plan(env = {})
    H::Cell.plan(bench: BENCH, env: { T::ENV_CORPUS => FIXTURE }.merge(env), today: TODAY, corpus: corpus)
  end

  # ---- the registry entry and the plan ----

  def test_the_registry_entry_is_a_local_distribution_with_the_launcher_and_its_three_env_names
    entry = H.registry_entry(nexus_url: "http://host.docker.internal:3000")
    assert_equal({ "cmd" => "/opt/rho/libexec/rho-acp-launch", "args" => [],
                   "env" => { "RHO_MODE" => "full", "RHO_TOOLS_ROOT" => "/app", "RHO_NEXUS_URL" => "http://host.docker.internal:3000" } },
      entry.fetch("distribution").fetch("local"))
    assert_equal %w[rho rho], entry.values_at("id", "name")
    assert_equal Rho::VERSION, entry.fetch("version"), "the version is rho's own"
    assert_equal ["local"], entry.fetch("distribution").keys, "no npx, uvx or binary: the launcher is already in the image (Q5 stands)"
    assert_equal H::LAUNCHER, entry.dig("distribution", "local", "cmd")
    assert_equal K::APP, H::TOOLS_ROOT

    # THE FILE IS THE BASE (the entry kept in the tree, not submitted): the gem's
    # `registry/rho/agent.json` reached by its repo-relative path; id, name, version, description,
    # repository, license, authors are the file's, the distribution alone the cell's — the file's
    # own is the bare exe, which is what an editor entry runs.
    assert_equal File.expand_path("../../agents/rho/rho-acp/registry/rho/agent.json", __dir__), H::REGISTRY_ENTRY_SOURCE
    file = JSON.parse(File.read(H::REGISTRY_ENTRY_SOURCE, encoding: Encoding::UTF_8))
    assert_equal file.values_at("id", "name", "version"), entry.values_at("id", "name", "version")
    assert_equal file.except("distribution"), entry.except("distribution")
    assert_equal({ "cmd" => "rho-acp", "args" => [] }, file.dig("distribution", "local"))
    assert_equal %w[id name version description repository authors license license_url distribution], entry.keys
  end

  def test_the_plan_takes_the_cells_model_and_k_from_the_bench_and_dates_the_label
    cell = plan
    assert_equal FLOOR, cell.model, "the default cell's first floor"
    assert_equal POLICY.runs_cap(FLOOR), cell.runs
    assert_equal %w[alpha-one beta-two], cell.tasks.map(&:name)
    assert_equal "2026-09-18-harbor-acp-#{E2E::Evals::Bench.slug(FLOOR)}", cell.label
    assert_equal cell.label, cell.job_name
    assert_equal File.join(H::DEFAULT_JOBS_DIR, cell.label), cell.job_dir
    assert_equal File.join(BENCH.runs_dir, cell.label), cell.run_dir
    assert_equal File.join(cell.job_dir, "rho-agent.json"), cell.entry_path
    assert_equal H::PLACEHOLDER_URL, cell.nexus_url
    assert_match(/placeholder/, cell.nexus_url_source)
    [H::ENV_NEXUS_URL, H::ENV_NEXUS_HOST, "unset: the world's own host", "under the world's port"].each do |name|
      assert_includes cell.nexus_url_source, name, "the placeholder's source names the three sources"
    end
    assert_includes plan(H::ENV_NEXUS_HOST => "10.0.0.115").nexus_url_source, "(10.0.0.115)", "and the host knob's value when set"
    assert_equal FIXTURE, cell.corpus_dir

    narrowed = plan("E2E_EVALS_TASKS" => "alpha-*", "E2E_EVALS_RUNS" => "1", "E2E_EVALS_LABEL" => "2026-09-01-calib",
      H::ENV_JOBS_DIR => "/srv/jobs", H::ENV_NEXUS_URL => "http://10.0.0.5:3111")
    assert_equal %w[alpha-one], narrowed.tasks.map(&:name)
    assert_equal 1, narrowed.runs
    assert_equal "2026-09-01-calib", narrowed.label, "a dated label rides as given"
    assert_equal "/srv/jobs/2026-09-01-calib", narrowed.job_dir
    assert_equal ["http://10.0.0.5:3111", H::ENV_NEXUS_URL], [narrowed.nexus_url, narrowed.nexus_url_source]

    capped = plan("E2E_EVALS_RUNS" => "99")
    assert_equal POLICY.runs_cap(FLOOR), capped.runs, "k never exceeds the cell's cap"

    # THE BOOTED WORLD (`with_world`, the lane's step — never E2E_BASE_URL
    # at plan time): its own host by default; the host knob under its port
    # (the box's LAN IP: harbor's compose bridge); the whole-URL override
    # over both. A new cell each time, the plan untouched.
    unbooted = plan("E2E_BASE_URL" => "http://127.0.0.1:3111")
    assert_equal H::PLACEHOLDER_URL, unbooted.nexus_url, "a world in the environment is not a booted world"
    booted = unbooted.with_world("http://127.0.0.1:3111", env: {})
    assert_equal ["http://127.0.0.1:3111", "the booted world's URL as it is (#{H::ENV_NEXUS_HOST} unset)"],
      [booted.nexus_url, booted.nexus_url_source]
    lan = unbooted.with_world("http://127.0.0.1:3111", env: { H::ENV_NEXUS_HOST => "10.0.0.115" })
    assert_equal ["http://10.0.0.115:3111", "#{H::ENV_NEXUS_HOST}=10.0.0.115 under the booted world's port"],
      [lan.nexus_url, lan.nexus_url_source]
    assert_equal "http://10.0.0.115:3111", lan.registry_entry.dig("distribution", "local", "env", "RHO_NEXUS_URL"),
      "the registry entry carries the address the containers reach"
    whole = unbooted.with_world("http://127.0.0.1:3111", env: { H::ENV_NEXUS_HOST => "10.0.0.115", H::ENV_NEXUS_URL => "http://10.0.0.5:3111" })
    assert_equal ["http://10.0.0.5:3111", H::ENV_NEXUS_URL], [whole.nexus_url, whole.nexus_url_source], "the whole URL wins over the host"
    assert_equal H::PLACEHOLDER_URL, unbooted.nexus_url, "`with` answers a new cell"
    assert_equal unbooted.to_h.except(:nexus_url, :nexus_url_source), lan.to_h.except(:nexus_url, :nexus_url_source), "and changes nothing else"
    assert_equal 2 * POLICY.runs_cap(FLOOR) * (900 + 1200) + E2E::Evals::Plan::BOOT_AND_TEARDOWN_SLACK_SECONDS, unbooted.journey_seconds,
      "the world's patience: 2 × Σ agent.timeout_sec (alpha-one 900 s, beta-two 1200 s) × k + the slack, no image slack"
    assert_equal 2 * 900 + E2E::Evals::Plan::BOOT_AND_TEARDOWN_SLACK_SECONDS, plan("E2E_EVALS_TASKS" => "alpha-*", "E2E_EVALS_RUNS" => "1").journey_seconds

    optional = POLICY.optional_models.first
    assert_equal optional, plan("E2E_EVALS_MODELS" => optional).model, "the optional cell's model when named"
    error = assert_raises(ArgumentError) { plan("E2E_EVALS_MODELS" => "openrouter/nobody/model") }
    assert_match(/not a model the bench names/, error.message)
    assert_match(/names no terminal-bench task/, assert_raises(ArgumentError) { plan("E2E_EVALS_TASKS" => "gamma-*") }.message)
  end

  def test_the_command_line_is_harbor_run_over_the_entry_with_the_two_kwargs_the_corpus_and_the_task_names
    cell = plan("E2E_EVALS_LABEL" => "2026-09-18-calib", H::ENV_JOBS_DIR => "/srv/jobs")
    assert_equal ["harbor", "run", "-a", "acp", "-m", FLOOR, "-k", POLICY.runs_cap(FLOOR).to_s,
                  "--agent-kwarg", "registry_entry_path=/srv/jobs/2026-09-18-calib/rho-agent.json",
                  "--agent-kwarg", "auth_policy=disabled", "--agent-kwarg", "permission_mode=allow",
                  "--jobs-dir", "/srv/jobs", "--job-name", "2026-09-18-calib",
                  "-p", "/srv/jobs/2026-09-18-calib/corpus", "-i", "alpha-one", "-i", "beta-two"], cell.argv
    assert_equal "/srv/jobs/2026-09-18-calib/corpus", cell.overlay_dir, "harbor reads the overlay under the job dir, never the corpus"
    assert_equal FIXTURE, cell.corpus_dir, "the corpus stays the overlay's source"
    assert_equal cell.argv.join(" "), cell.command, "nothing in the argv needs quoting"
    # The box spells harbor `uvx --from harbor harbor`; the default is the bare word.
    assert_equal %w[harbor], H.harbor_command({})
    assert_equal %w[uvx --from harbor harbor], H.harbor_command(H::ENV_HARBOR_COMMAND => "uvx --from harbor harbor")
    spelled = H.run_argv(entry_path: "/e.json", model: FLOOR, runs: 1, corpus_dir: "/c", task_names: %w[alpha-one],
      jobs_dir: "/j", job_name: "n", harbor: %w[uvx --from harbor harbor])
    assert_equal %w[uvx --from harbor harbor run -a acp -m] + [FLOOR], spelled.first(9)
    assert_equal ["rho-evals-example.invalid-alpha-one-20251031-app-owner-base", "rho-evals-example.invalid-beta-two-20251031-app-owner-base"],
      cell.tags, "the plain driver's tags: the base slugged, the app tree the base's (terminal-bench runs as root)"
    assert_equal cell.tags, cell.tasks.map { |task| cell.tag_for(task) }
    assert_equal "/srv/jobs/2026-09-18-calib/corpus/beta-two", cell.overlay_task_dir(cell.tasks.last)

    text = cell.describe
    assert_includes text, cell.command
    assert_includes text, JSON.pretty_generate(cell.registry_entry)
    cell.tags.each { |tag| assert_includes text, tag }
    assert_includes text, "  the 2 derived tag(s) the overlay is FROM", "the tags listed where the overlay uses them"
    assert_includes text, "docker ps --format {{.ID}}", "every running container by id"
    refute_includes text, "--filter ancestor=", "never the image: the box's BuildKit build left no parent chain for the filter"
    assert_includes text, "docker exec <container> cat /var/lib/rho/tmp/acp-ceremony.json"
    assert_includes text, "the sidecar's probe is one docker exec per unpaired running container per poll"
    assert_includes text, "assumptions the dry run cannot check"
    assert_includes text, "  overlay:     /srv/jobs/2026-09-18-calib/corpus"
    assert_includes text, "overlay task → /srv/jobs/2026-09-18-calib/corpus/alpha-one"
    assert_includes text, "    FROM rho-evals-example.invalid-alpha-one-20251031-app-owner-base\n    ENTRYPOINT [\"/usr/bin/tini\", \"--\"]\n" \
                          "    CMD [\"sleep\", \"infinity\"]\n    USER 0\n", "the dry run prints one task's Dockerfile"
    assert_includes text, "    [environment]\n    build_timeout_sec = 600.0\n    cpus = 1\n", "and its task.toml, docker_image gone"
    refute_includes text, "docker_image = "
    assert_includes text, "HANDLED, no longer assumed: the derived image's ENTRYPOINT"

    Dir.mktmpdir("harbor-acp") do |root|
      cell = plan(H::ENV_JOBS_DIR => root)
      path = H.write_registry_entry(cell)
      assert_equal cell.entry_path, path
      assert_equal cell.registry_entry, JSON.parse(File.read(path, encoding: Encoding::UTF_8))

      assert_equal cell.overlay_dir, H.write_overlay(cell)
      assert_equal %w[alpha-one beta-two], Dir.children(cell.overlay_dir).sort, "one overlay task dir per selected task"
      cell.tasks.each do |task|
        assert_equal "FROM #{cell.tag_for(task)}\n", File.readlines(File.join(cell.overlay_task_dir(task), "environment", "Dockerfile")).first
      end
    end
  end

  # ---- the overlay task ----

  def test_the_overlay_task_is_the_corpus_task_copied_onto_its_derived_tag_with_a_neutral_entrypoint
    tag = "rho-evals-example.invalid-alpha-one-20251031-app-owner-base"
    source = File.join(FIXTURE, "alpha-one")
    Dir.mktmpdir("harbor-acp-overlay") do |root|
      into = File.join(root, "corpus", "alpha-one")
      assert_equal into, H.write_overlay_task(source, tag: tag, into: into)

      assert_equal File.binread(File.join(source, "instruction.md")), File.binread(File.join(into, "instruction.md")), "byte-identical"
      %w[test.sh test_outputs.py].each do |file|
        assert_equal File.binread(File.join(source, "tests", file)), File.binread(File.join(into, "tests", file)), "tests/#{file} as it is"
        assert_equal File.stat(File.join(source, "tests", file)).mode, File.stat(File.join(into, "tests", file)).mode, "its mode kept"
      end
      assert_equal %w[environment instruction.md task.toml tests], Dir.children(into).sort

      dockerfile = File.read(File.join(into, "environment", "Dockerfile"), encoding: Encoding::UTF_8)
      assert_equal ["FROM #{tag}", 'ENTRYPOINT ["/usr/bin/tini", "--"]', 'CMD ["sleep", "infinity"]', "USER 0"], dockerfile.lines(chomp: true),
        "FROM the derived tag; tini alone so harbor's own command runs; the base's default user (the plain driver's --user 0)"
      assert_equal ["Dockerfile"], Dir.children(File.join(into, "environment")), "the environment dir is the overlay's alone"

      original = File.read(File.join(source, "task.toml"), encoding: Encoding::UTF_8)
      rewritten = File.read(File.join(into, "task.toml"), encoding: Encoding::UTF_8)
      assert_equal original.lines.reject { |line| line.start_with?("docker_image = ") }.join, rewritten, "their bytes but the one line"
      toml = TomlRB.parse(rewritten)
      assert_nil toml.dig("environment", "docker_image")
      assert_equal({ "build_timeout_sec" => 600.0, "cpus" => 1, "memory" => "2G", "storage" => "10G" }, toml.fetch("environment"))
      assert_equal "1.0", toml.fetch("version")
      assert_includes rewritten, "# A two-task sample of harbor's", "the comments ride"
      assert_equal "0", T::CONTAINER_USER, "USER is the family's container user"
    end

    # A corpus task in their full shape — environment/ with the base's
    # recipe and its assets, solution/ — and a stale overlay in the way.
    Dir.mktmpdir("harbor-acp-overlay-full") do |root|
      full = File.join(root, "corpus", "alpha-one")
      FileUtils.mkdir_p(File.dirname(full))
      FileUtils.cp_r(source, full, preserve: true)
      FileUtils.mkdir_p(File.join(full, "environment"))
      File.write(File.join(full, "environment", "Dockerfile"), "FROM ubuntu:24.04\nCOPY make.py /app\n")
      File.write(File.join(full, "environment", "make.py"), "print(1)\n")
      FileUtils.mkdir_p(File.join(full, "solution"))
      File.write(File.join(full, "solution", "solve.sh"), "#!/bin/bash\necho 3 > /app/answer.py\n")
      File.chmod(0o755, File.join(full, "solution", "solve.sh"))

      into = File.join(root, "overlay", "alpha-one")
      FileUtils.mkdir_p(File.join(into, "tests"))
      File.write(File.join(into, "tests", "stale.py"), "")
      H.write_overlay_task(full, tag: tag, into: into)
      assert_equal %w[environment instruction.md solution task.toml tests], Dir.children(into).sort, "solution/ rides"
      assert_equal ["Dockerfile"], Dir.children(File.join(into, "environment")), "their Dockerfile and its assets never ride"
      assert_equal "FROM #{tag}\n", File.readlines(File.join(into, "environment", "Dockerfile")).first
      assert_equal 0o755, File.stat(File.join(into, "solution", "solve.sh")).mode & 0o777, "an executable stays one"
      assert_equal %w[test.sh test_outputs.py], Dir.children(File.join(into, "tests")).sort, "a stale overlay is replaced whole"
    end

    inline = "version = \"1.0\"\nenvironment = { docker_image = \"example.invalid/x:1\", cpus = 1 }\n"
    error = assert_raises(ArgumentError) { H.overlay_task_toml(inline, name: "alpha-one") }
    assert_match(/alpha-one: task.toml's docker_image survived the overlay/, error.message, "a spelling the line rule misses is refused by name")
  end

  # THE RUN'S ORDER, with a `true` for harbor: the overlay stands under the
  # job dir before harbor is spawned from it, and the argv names it; the
  # booted world is a kwarg (the lane's), never the environment; the
  # outcome carries harbor's exit, the pairings and the records; a cell
  # still at the plan's placeholder is refused by name.
  def test_the_run_writes_the_overlay_before_harbor_is_spawned
    Dir.mktmpdir("harbor-acp-run") do |root|
      cell = plan(H::ENV_JOBS_DIR => root).with_world("http://127.0.0.1:3111", env: { H::ENV_NEXUS_HOST => "10.0.0.115" })
      seen = nil
      spawn = lambda do |*argv, **options|
        seen = { argv: argv, chdir: options[:chdir], overlay: Dir.exist?(cell.overlay_dir),
                 dockerfiles: cell.tasks.map { |task| File.file?(File.join(cell.overlay_task_dir(task), "environment", "Dockerfile")) } }
        Process.spawn("true", in: File::NULL, out: File::NULL, err: File::NULL)
      end
      docker = ->(argv) { argv[1] == "ps" ? ["", OK] : flunk("an unexpected docker call: #{argv.inspect}") }
      outcome = H.run!(cell, base_url: "http://127.0.0.1:3111", docker: docker, spawn: spawn,
        confirm: ->(_started) { flunk "nothing to pair" }, out: StringIO.new)
      assert_empty outcome.records, "no trial, no record"
      assert_predicate outcome.status, :success?
      assert_empty outcome.paired
      assert_equal cell.argv, seen.fetch(:argv)
      assert_equal cell.job_dir, seen.fetch(:chdir)
      assert seen.fetch(:overlay), "the overlay stands when harbor starts"
      assert_equal [true, true], seen.fetch(:dockerfiles)
      assert_path_exists cell.entry_path
      assert_equal "http://10.0.0.115:3111", JSON.parse(File.read(cell.entry_path)).dig("distribution", "local", "env", "RHO_NEXUS_URL")

      error = assert_raises(ArgumentError) { H.run!(plan(H::ENV_JOBS_DIR => root), base_url: "http://127.0.0.1:3111", spawn: spawn) }
      assert_match(/the plan's placeholder/, error.message)
    end
  end

  # THE LANE FILE parses and names the steps it takes (it runs only on the
  # box: a world, harbor, the provider key).
  def test_the_lane_file_parses_and_takes_the_lanes_steps
    lane = File.expand_path("../evals/harbor_acp_lane_test.rb", __dir__)
    _out, err, status = Open3.capture3(Gem.ruby, "-c", lane)
    assert_predicate status, :success?, "ruby -c: #{err}"
    text = File.read(lane, encoding: Encoding::UTF_8)
    %w[start_live_journey! price_and_open_lane! with_world(@base_url HarborAcp.run!(cell, base_url: @base_url
       E2E::Ceremony.confirm(actor: @actor finish_live_journey!].each { |step| assert_includes text, step }
    assert_includes File.read(File.expand_path("../tasks/diagnostics.rake", __dir__), encoding: Encoding::UTF_8),
      'run_e2e_tests("harbor_acp_lane_test", journey_seconds: cell.journey_seconds, teardown_seconds: 600)'
  end

  # ---- the launcher ----

  def test_the_launcher_is_executable_parses_and_is_copied_into_the_image_after_the_install
    assert_path_exists H::LAUNCHER_SOURCE
    assert File.executable?(H::LAUNCHER_SOURCE), "the launcher is executable (COPY keeps the mode)"
    _out, err, status = Open3.capture3("bash", "-n", H::LAUNCHER_SOURCE)
    assert_predicate status, :success?, "bash -n: #{err}"

    script = File.read(H::LAUNCHER_SOURCE, encoding: Encoding::UTF_8)
    assert_includes script, 'setsid rho server --mode full --display-name harbor-acp </dev/null >"$LOG" 2>&1 &',
      "the daemon in its own session, all three fds redirected"
    assert_includes script, 'LOG="$RHO_HOME/log/acp-launch.log"'
    assert_includes script, 'CEREMONY="$RHO_HOME/tmp/acp-ceremony.json"'
    assert_match(/^exec_rho_acp "\$@"$/, script, "the last line execs the surface with harbor's argv")
    assert_includes script, 'exec rho-acp "$@"'
    assert_includes script, '"$RHO_PREFIX/current/agents/rho/rho-acp/exe/rho-acp"', "the exe the wrapper's way when no launcher is on PATH"
    assert_includes script, "adopted)", "a second invocation finds the daemon adopted and serves at once"
    assert_equal 2, script.scan(/^\s*door ceremony "\$CEREMONY" >&2$/).size, "the ceremony's stdout on stderr: fd 1 is the wire"
    assert_equal 2, script.scan(/^\s*door await "\$ADOPT_TIMEOUT" >&2$/).size

    dockerfile = File.read(K::DOCKERFILE, encoding: Encoding::UTF_8)
    copy = "COPY --chown=1000:1000 e2e/evals/docker/rho-acp-launch /opt/rho/libexec/rho-acp-launch"
    assert_includes dockerfile, copy
    assert_operator dockerfile.index("install/install.sh --from-checkout /rho/src"), :<, dockerfile.index(copy), "after the install RUN: the prefix exists then"
    assert_operator dockerfile.index(copy), :<, dockerfile.index("\nENTRYPOINT ["), "before the door"
    ignore = File.read(File.join(K::CONTEXT, ".dockerignore"), encoding: Encoding::UTF_8)
    assert_includes ignore.lines(chomp: true), "!e2e/evals/docker/rho-acp-launch", "the root context lets the one file through"
  end

  # THE DOOR: the launcher's embedded ruby, run as the launcher runs it
  # (`ruby - VERB ARG` reading the program from stdin), against a fake
  # daemon on loopback whose answers are scripted per path.
  def test_the_launchers_door_probes_starts_the_ceremony_and_awaits_the_adoption
    door = File.read(H::LAUNCHER_SOURCE, encoding: Encoding::UTF_8)[/<<'RUBY'\n(.*?)\nRUBY\n/m, 1]
    refute_nil door, "the door is a heredoc"
    Dir.mktmpdir("harbor-acp-door") do |home|
      FileUtils.mkdir_p(File.join(home, "tmp"))
      run = ->(*argv) { Open3.capture3({ "RHO_HOME" => home }, Gem.ruby, "-", *argv, stdin_data: door) }

      out, = run.call("probe")
      assert_equal "none", out.strip, "no announcement"

      dead = TCPServer.new("127.0.0.1", 0)
      port = dead.addr[1]
      dead.close
      announce(home, port)
      out, = run.call("probe")
      assert_equal "none", out.strip, "an announcement nobody answers"

      with_fake_daemon(home) do |daemon|
        daemon.answers["/status"] = [[200, { "state" => "active", "workspace" => { "state" => "pending" } }]]
        out, = run.call("probe")
        assert_equal "pending", out.strip

        ceremony = File.join(home, "tmp", "acp-ceremony.json")
        daemon.answers["/device/start"] = [
          [503, { "error" => { "code" => "connection_bootstrapping", "message" => "still checking" } }],
          [200, { "phase" => "pending", "branch" => "combined", "user_code" => "ABCD-1234",
                  "verification_uri" => "http://127.0.0.1:#{daemon.port}/device",
                  "verification_uri_complete" => "http://127.0.0.1:#{daemon.port}/device?code=ABCD-1234" }],
        ]
        _out, err, status = run.call("ceremony", ceremony)
        assert_predicate status, :success?, err
        assert_equal "ABCD-1234", JSON.parse(File.read(ceremony)).fetch("user_code"), "the answer past the bootstrapping window, written whole"
        assert_equal %w[POST POST], daemon.seen.select { |verb, path| path == "/device/start" }.map(&:first), "retried once through the 503"
        refute_path_exists "#{ceremony}.tmp"

        daemon.answers["/device/start"] = [[409, { "error" => { "code" => "already_connected", "message" => "Already connected" } }]]
        _out, err, status = run.call("ceremony", ceremony)
        assert_predicate status, :success?, err
        assert_equal "already_connected", JSON.parse(File.read(ceremony)).dig("error", "code"), "written too: a document with no code"

        daemon.answers["/device/start"] = [[200, { "phase" => "error", "branch" => "combined", "mode" => "full",
                                                   "error" => "the device authorization request failed" }]]
        _out, err, status = run.call("ceremony", ceremony)
        assert_predicate status, :success?, err
        assert_equal "error", JSON.parse(File.read(ceremony)).fetch("phase"), "a 200 carrying the connection's own error is written, never refused"

        daemon.answers["/device/start"] = [[409, { "error" => { "code" => "too_late", "message" => "the ceremony expired" } }]]
        _out, err, status = run.call("ceremony", ceremony)
        refute_predicate status, :success?
        assert_includes err, "/device/start refused: the ceremony expired"

        daemon.answers["/status"] = [[200, { "state" => "active", "workspace" => { "state" => "pending" } }],
                                     [200, { "state" => "active", "workspace" => { "state" => "adopted", "public_id" => "wks_1" } }]]
        out, err, status = run.call("await", "20")
        assert_predicate status, :success?, err
        assert_equal "", out, "nothing on stdout: fd 1 is the wire"

        daemon.answers["/status"] = [[200, { "state" => "active", "workspace" => { "state" => "error", "code" => "not_a_room" } }]]
        _out, err, status = run.call("await", "20")
        refute_predicate status, :success?
        assert_includes err, "workspace failed: error:not_a_room"

        daemon.answers["/status"] = [[200, { "state" => "active", "workspace" => { "state" => "pending" } }]]
        _out, err, status = run.call("await", "0")
        refute_predicate status, :success?
        assert_includes err, "not adopted within 0 s"
      end
    end
  end

  # ---- the sidecar ----

  # DISCOVERY BY THE DOCUMENT, NOT THE IMAGE (the box cell
  # 2026-09-19-harbor-acp-dry, third launch: the launcher inside the task
  # container wrote the file and waited its full 300 s while the sidecar
  # "paired 0 container(s)" — the overlay's BuildKit image records no
  # parent chain, so `docker ps --filter ancestor=<derived tag>` never saw
  # it): one `docker ps` for every running container by id, then one
  # `docker exec … cat` per unpaired one; a container without the file yet
  # is probed again every poll and paired once it appears; a confirmed one
  # is never read again; a foreign container — no file, ever — is probed
  # and never paired; the log names the id and the code's tail.
  def test_the_sidecar_confirms_each_container_once_off_its_ceremony_document_read_through_docker_exec
    ours = "3f2a1c9d0e4b"
    late = "8b7c6d5e4f30"
    running = [ours, late]
    files = { ours => pairing("ABCD-1234") }
    no_file = "cat: /var/lib/rho/tmp/acp-ceremony.json: No such file or directory\n"
    docker = lambda do |argv|
      case argv[1]
      when "ps" then ["#{running.join("\n")}\n", OK]
      when "exec" then files.key?(argv[2]) ? [files.fetch(argv[2]), OK] : [no_file, NO]
      else flunk "an unexpected docker call: #{argv.inspect}"
      end
    end
    confirmed = []
    log = StringIO.new
    sidecar = H::Sidecar.new(confirm: ->(started) { confirmed << started }, docker: docker,
      nexus_url: "http://host.docker.internal:3000", base_url: "http://127.0.0.1:3000", log: log)
    execs_of = ->(id) { sidecar.calls.count { |argv| argv[1] == "exec" && argv[2] == id } }

    assert_equal [ours, late], sidecar.poll, "every running container, by id"
    assert_equal 1, confirmed.size, "the one container whose document carries a code"
    assert_equal "ABCD-1234", confirmed.first.fetch("user_code")
    assert_equal "http://127.0.0.1:3000/device?code=ABCD-1234", confirmed.first.fetch("verification_uri_complete"),
      "host.docker.internal rewritten for the steward's browser on the host"
    assert_equal({ ours => "ABCD-1234" }, sidecar.confirmed)
    assert_equal [%w[docker ps --format {{.ID}}],
                  ["docker", "exec", ours, "cat", "/var/lib/rho/tmp/acp-ceremony.json"],
                  ["docker", "exec", late, "cat", "/var/lib/rho/tmp/acp-ceremony.json"]], sidecar.calls,
      "no image filter: one ps, then one exec per unpaired container"
    assert_equal ["sidecar: paired #{ours} (code ending 1234)"], log.string.lines(chomp: true), "the id and the code's tail, never the whole code"

    sidecar.poll
    assert_equal 1, confirmed.size, "a container without the file is not paired"
    assert_equal 2, execs_of.call(late), "and is probed again next poll"
    files[late] = JSON.generate("error" => { "code" => "already_connected", "message" => "Already connected" })
    sidecar.poll
    assert_equal 1, confirmed.size, "a document with no code is never confirmed"
    files[late] = "{\"phase\": \"pen"
    sidecar.poll
    assert_equal 1, confirmed.size, "a half-written file is asked again next time"
    files[late] = pairing("WXYZ-9999")
    sidecar.poll
    assert_equal %w[ABCD-1234 WXYZ-9999], confirmed.map { |started| started["user_code"] }
    assert_equal 1, execs_of.call(ours), "a confirmed container is never read again"
    assert_equal 5, execs_of.call(late), "the late one was probed on every poll until its file appeared"

    # A foreign container (no file, ever) beside a third of ours, both
    # seen by `run`'s two polls (one, done, one last).
    foreign = "ffff00001111"
    third = "c0ffee000001"
    running += [foreign, third]
    files[third] = pairing("BETA-0001")
    assert_equal [ours, late, third], sidecar.run(done: -> { true }, every: 0)
    assert_equal 3, confirmed.size
    assert_equal 2, execs_of.call(foreign), "a foreign container is probed each poll and never paired"
    assert_equal 1, execs_of.call(third)
    assert_equal 5, execs_of.call(late), "the paired are not probed by run's polls"
    assert_equal ["sidecar: paired #{ours} (code ending 1234)", "sidecar: paired #{late} (code ending 9999)",
                  "sidecar: paired #{third} (code ending 0001)"], log.string.lines(chomp: true)
  end

  # THE PAIRING DOCUMENT AT THE STEWARD'S ORIGIN: Nexus answered the
  # daemon at the containers' address (the box's LAN IP under the world's
  # port); the steward's cookie is on the harness's — the two URLs move,
  # the rest rides; a URL elsewhere already is left alone; the answer is
  # never mutated.
  def test_the_pairing_document_is_rewritten_from_the_containers_origin_to_the_stewards
    answer = { "verification_uri_complete" => "http://10.0.0.115:3111/oauth/device?user_code=ABCD-EFGH",
               "verification_uri" => "http://10.0.0.115:3111/oauth/device", "user_code" => "ABCD-EFGH", "branch" => "combined" }.freeze
    seen = H.pairing_for_steward(answer, nexus_url: "http://10.0.0.115:3111", base_url: "http://127.0.0.1:3111")
    assert_equal "http://127.0.0.1:3111/oauth/device?user_code=ABCD-EFGH", seen["verification_uri_complete"]
    assert_equal "http://127.0.0.1:3111/oauth/device", seen["verification_uri"]
    assert_equal %w[ABCD-EFGH combined], seen.values_at("user_code", "branch")
    assert_equal "http://10.0.0.115:3111/oauth/device", answer["verification_uri"], "the answer is not mutated"

    same = H.pairing_for_steward(answer, nexus_url: "http://127.0.0.1:3111", base_url: "http://127.0.0.1:3111")
    assert_equal answer, same, "the world's own host: a container on the host's network answers the steward's origin already"
    other_port = H.pairing_for_steward(answer, nexus_url: "http://10.0.0.115:3999", base_url: "http://127.0.0.1:3111")
    assert_equal answer, other_port, "another origin is not the containers' and rides as it is"
    assert_equal({ "error" => { "code" => "x" } },
      H.pairing_for_steward({ "error" => { "code" => "x" } }, nexus_url: "http://10.0.0.115:3111", base_url: "http://127.0.0.1:3111"))
  end

  # ---- the import and the ledger row ----

  def test_a_deadline_after_connection_metadata_is_a_lane_failure_until_model_work_arrives
    Dir.mktmpdir("harbor-acp-startup") do |root|
      trial(root, "alpha-one__startup", events: 1, reward_text: "0\n",
        result: { "task_name" => "alpha-one",
                  "exception_info" => { "exception_type" => "AgentTimeoutError" } })
      events = File.join(root, "alpha-one__startup", "agent", "acp-events.jsonl")
      # Harbor records this prefix before any model output or tool work.
      prefix = [
        { "event_type" => "on_connect", "payload" => { "connection" => "ClientSideConnection" } },
        { "event_type" => "session_update", "payload" => { "session_id" => "session",
          "update" => { "sessionUpdate" => "available_commands_update", "availableCommands" => [] } } },
      ]
      File.write(events, prefix.map { |row| JSON.generate(row) }.join("\n") + "\n")

      record = H.import(root, model: FLOOR, bench: BENCH, known: ["alpha-one"]).sole
      assert_equal E2E::Evals::Scorecard::LANE_BUG, record.dig("verdict", "class")
      assert_equal "deadline", record.fetch("stopped")
      assert_equal({ "on_connect" => 1, "available_commands_update" => 1 }, record.dig("facts", "events"))

      update = { "event_type" => "session_update", "payload" => { "session_id" => "session",
        "update" => { "sessionUpdate" => "agent_thought_chunk", "content" => { "type" => "text", "text" => "Working" } } } }
      File.open(events, "a") { |file| file.puts(JSON.generate(update)) }

      working = H.import(root, model: FLOOR, bench: BENCH, known: ["alpha-one"]).sole
      assert_equal E2E::Evals::Scorecard::MODEL_CONDUCT, working.dig("verdict", "class")
      assert_equal 1, working.dig("facts", "events", "agent_thought_chunk")
      assert_equal "deadline (failed)", E2E::Evals::Scorecard.kind_of(working, bench: BENCH)
    end
  end

  def test_the_import_reads_one_record_per_trial_with_the_reward_as_task_pass_and_the_ledger_lists_the_cell
    Dir.mktmpdir("harbor-acp-import") do |root|
      job = File.join(root, "jobs", "2026-09-18-calib")
      trial(job, "alpha-one__x1", events: 3, summary: { "prompt_response" => { "stopReason" => "end_turn" }, "errors" => [] },
        result: { "task_name" => "alpha-one", "started_at" => "2026-09-18T10:00:00Z", "finished_at" => "2026-09-18T10:05:30Z",
                  "verifier_result" => { "rewards" => { "reward" => 1.0 } } })
      trial(job, "alpha-one__x2", events: 2, reward_text: "0\n", torn: true)
      trial(job, "beta-two.1-of-1", events: 2, summary: { "prompt_response" => nil, "errors" => ["AgentTimeoutError: 900 s"] })
      # HARBOR CUT THE AGENT AT ITS BUDGET: a reward of zero and its own
      # exception on the result, the model working to the wire.
      trial(job, "gamma-three__x1", events: 4, reward_text: "0\n",
        result: { "task_name" => "gamma-three", "started_at" => "2026-09-18T11:00:00Z",
                  "finished_at" => "2026-09-18T11:16:07Z",
                  "exception_info" => { "exception_type" => "AgentTimeoutError", "message" => "agent exceeded 900 s" } })

      records = H.import(job, model: FLOOR, bench: BENCH, known: %w[alpha-one beta-two gamma-three])
      assert_equal [["alpha-one", FLOOR, "acp", 1], ["alpha-one", FLOOR, "acp", 2], ["beta-two", FLOOR, "acp", 1],
                    ["gamma-three", FLOOR, "acp", 1]],
        records.map { |record| E2E::Evals::Records.key(record) }

      passed, failed, errored, cut = records
      assert_equal({ "reached" => nil, "succeeded" => nil, "task_pass" => true, "class" => nil }, passed.fetch("verdict"), "no reach dimension; the reward passes")
      assert_equal %w[terminal-bench terminal-bench.alpha-one harbor-acp], passed.values_at("family", "capability", "driver")
      assert_equal BENCH.digest, passed.fetch("bench_digest")
      assert_equal ["2026-09-18T10:00:00Z", 330], passed.values_at("started_at", "seconds"), "harbor's own clock"
      assert_equal 1.0, passed.dig("facts", "reward")
      assert_equal "end_turn", passed.dig("facts", "stop_reason")
      assert_equal({ "agent_message_chunk" => 2, "session/request_permission" => 1 }, passed.dig("facts", "events"))
      assert_equal File.join(job, "alpha-one__x1", "agent", "acp-events.jsonl"), passed.fetch("artifact")
      refute passed.key?("error")

      assert_equal false, failed.dig("verdict", "task_pass")
      assert_equal E2E::Evals::Scorecard::MODEL_CONDUCT, failed.dig("verdict", "class")
      assert_equal "reward.txt: 0.0", failed.fetch("reason"), "the verifier's own file when harbor wrote no result"
      assert_equal({ "agent_message_chunk" => 1, "unparseable" => 1 }, failed.dig("facts", "events"))
      refute_nil failed["started_at"], "the events file's own clock"

      assert_equal false, errored.dig("verdict", "task_pass")
      assert_equal E2E::Evals::Scorecard::LANE_BUG, errored.dig("verdict", "class"), "harbor's own error is never the model's conduct"
      assert_equal "harbor: AgentTimeoutError: 900 s", errored.fetch("error")
      assert_match(/no result.json reward and no verifier\/reward.txt/, errored.fetch("reason"))

      # THE BUDGET CUT READS AS ONE: harbor's exception is on the record, the
      # stop is the deadline word every driver uses, and the class is the
      # model's conduct — it worked (four events) and ran out of time — never
      # a bare failed reward beside a verification failure.
      assert_equal false, cut.dig("verdict", "task_pass")
      assert_equal "deadline", cut.fetch("stopped")
      assert_equal "AgentTimeoutError", cut.dig("facts", "harbor_exception")
      assert_equal E2E::Evals::Scorecard::MODEL_CONDUCT, cut.dig("verdict", "class")
      assert_equal "deadline (failed)", E2E::Evals::Scorecard.kind_of(cut, bench: BENCH), "the verifier ran and said no"
      assert_equal "AgentTimeoutError — reward.txt: 0.0", cut.fetch("reason")

      records.each { |record| assert_kind_of String, E2E::Evals::ReportLine.render(record) }

      runs_dir = File.join(root, "runs")
      records.each { |record| E2E::Evals::Records.append(File.join(runs_dir, "2026-09-18-harbor-acp-floor"), record) }
      text = E2E::Evals::Ledger.render(runs_dir, bench: BENCH)
      assert_includes text, "| terminal-bench | alpha-one | #{FLOOR} (floor, read-only) | acp | r— s— p1/2 c— |"
      assert_includes text, "| terminal-bench | beta-two | #{FLOOR} (floor, read-only) | acp | r— s— p0/1 c— |"
      assert_includes text, "| terminal-bench | gamma-three | #{FLOOR} (floor, read-only) | acp | r— s— p0/1 c— |"

      assert_empty H.import(File.join(root, "absent"), model: FLOOR, bench: BENCH)
    end
  end

  # DOCUMENTS OFF THEIR SHAPE ARE READ LENIENTLY, NEVER RAISED: a ceremony document that is not a
  # pairing is never confirmed; a result, a reward, a name or a clock off harbor's shape falls back
  # to the verifier's file, the directory's name and the events file's clock; an events line that
  # is not an object is not counted.
  def test_a_ceremony_document_that_is_not_a_pairing_is_never_confirmed
    uri = "http://host.docker.internal:3000/device?code=AB"
    ["[]", "\"ABCD-1234\"", "5", "null",
     JSON.generate("user_code" => "", "verification_uri_complete" => uri),
     JSON.generate("user_code" => 1234, "verification_uri_complete" => uri),
     JSON.generate("user_code" => "ABCD-1234", "verification_uri_complete" => { "href" => uri })].each do |text|
      confirmed = []
      docker = ->(argv) { argv[1] == "ps" ? ["c1\n", OK] : [text, OK] }
      H::Sidecar.new(confirm: ->(started) { confirmed << started }, docker: docker, log: StringIO.new).poll
      assert_empty confirmed, text
    end
  end

  def test_a_result_off_harbors_shape_reads_the_verifiers_file_the_dirs_name_and_the_events_clock
    Dir.mktmpdir("harbor-acp-lenient") do |root|
      trial(root, "alpha-one__x1", events: 1, reward_text: "0\n", result: [])
      trial(root, "beta-two__x1", events: 1, reward_text: "0\n",
        result: { "task_name" => 7, "started_at" => 5, "verifier_result" => { "rewards" => { "reward" => "1" } } })
      trial(root, "beta-two__x2", events: 1, reward_text: "0\n", result: { "task_name" => "", "reward" => "1.0", "started_at" => "not a time" })
      events = File.join(root, "alpha-one__x1", "agent", "acp-events.jsonl")
      File.write(events, "[]\n\"x\"\n5\n#{JSON.generate("method" => "session/update")}\n")

      listed, typed, blank = H.import(root, model: FLOOR, bench: BENCH, known: %w[alpha-one beta-two])
      assert_equal ["alpha-one", false, "reward.txt: 0.0"], [listed["task"], listed.dig("verdict", "task_pass"), listed["reason"]],
        "a result.json that is not an object is no result"
      assert_equal({ "session/update" => 1 }, listed.dig("facts", "events"), "an events line that is not an object is not counted")
      assert_equal ["beta-two", false, "reward.txt: 0.0"], [typed["task"], typed.dig("verdict", "task_pass"), typed["reason"]],
        "a String reward is not harbor's number, a numeric task_name not its name"
      assert_equal ["beta-two", false, "reward.txt: 0.0"], [blank["task"], blank.dig("verdict", "task_pass"), blank["reason"]]
      [typed, blank].each { |record| refute_nil record["started_at"], "a clock that is not an ISO-8601 String is the events file's" }
      assert_nil H::Trial.time_of({ "started_at" => 5 }, "started_at")
      assert_nil H::Trial.time_of({ "started_at" => "not a time" }, "started_at")
      assert_equal "beta-two", H::Trial.task_of("beta-two__x1", { "task_name" => 7 }, [])
      assert_equal [1.0, "result.json: 1"], H::Trial.reward_of({ "reward" => 1 }, root), "harbor's bare Integer reward"
      assert_equal [1.0, "result.json: 1.0"], H::Trial.reward_of({ "verifier_result" => { "rewards" => [1.0] }, "reward" => 1.0 }, root),
        "rewards that are not a table fall back to the bare reward"
      scalar = File.join(root, "scalar.json")
      File.write(scalar, JSON.generate("x"))
      assert_nil H::Trial.read_json(scalar), "a JSON document that is not an object is no result"
    end
  end

  private

    def announce(home, port)
      File.write(File.join(home, "tmp", "announcement.json"),
        JSON.generate("endpoint" => "http://127.0.0.1:#{port}", "bearer" => "test-bearer"))
    end

    def pairing(code)
      JSON.generate("phase" => "pending", "branch" => "combined", "mode" => "full", "user_code" => code,
        "verification_uri" => "http://host.docker.internal:3000/device",
        "verification_uri_complete" => "http://host.docker.internal:3000/device?code=#{code}")
    end

    # A trial dir in harbor's shape: `agent/acp-events.jsonl` (n update
    # lines, the last a permission request; a torn line when asked), the
    # summary, and the reward as `result.json` or `verifier/reward.txt`.
    def trial(job, name, events:, summary: nil, result: nil, reward_text: nil, torn: false)
      dir = File.join(job, name)
      FileUtils.mkdir_p(File.join(dir, "agent"))
      lines = Array.new(events - 1) { JSON.generate("method" => "session/update", "params" => { "update" => { "sessionUpdate" => "agent_message_chunk" } }) }
      lines << (torn ? "{\"method\": \"session/upd" : JSON.generate("method" => "session/request_permission", "params" => {}))
      File.write(File.join(dir, "agent", "acp-events.jsonl"), "#{lines.join("\n")}\n")
      File.write(File.join(dir, "agent", "acp-summary.json"), JSON.generate(summary)) if summary
      File.write(File.join(dir, "result.json"), JSON.generate(result)) if result
      return unless reward_text

      FileUtils.mkdir_p(File.join(dir, "verifier"))
      File.write(File.join(dir, "verifier", "reward.txt"), reward_text)
    end

    # THE FAKE DAEMON: one loopback listener, each connection one HTTP
    # request answered off `answers[path]` — a queue whose last answer
    # repeats — and remembered in `seen`.
    FakeDaemon = Struct.new(:port, :answers, :seen)

    def with_fake_daemon(home)
      server = TCPServer.new("127.0.0.1", 0)
      daemon = FakeDaemon.new(server.addr[1], {}, [])
      announce(home, daemon.port)
      thread = Thread.new do
        loop do
          socket = server.accept
          serve(socket, daemon)
        rescue IOError, Errno::EBADF
          break
        end
      end
      yield daemon
    ensure
      server&.close
      thread&.join(2)
    end

    def serve(socket, daemon)
      request = socket.gets
      verb, path = request.to_s.split(" ")
      loop do
        line = socket.gets
        break if line.nil? || line.strip.empty?
      end
      daemon.seen << [verb, path]
      queue = daemon.answers.fetch(path, [[404, { "error" => { "code" => "not_found", "message" => path } }]])
      code, body = queue.size > 1 ? queue.shift : queue.first
      json = JSON.generate(body)
      socket.write("HTTP/1.1 #{code} X\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
    ensure
      socket.close
    end
end
