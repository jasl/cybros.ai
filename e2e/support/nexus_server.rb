require "net/http"
require "fileutils"
require "securerandom"
require "json"
require "socket"
require "time"
require "uri"
require_relative "process_runner"

require_relative "catalog_overlay"
require_relative "failure_dump"
require_relative "nexus_hosts"
require_relative "mock_llm/server"
require_relative "secret_hygiene"

module E2E
  # Owns an isolated Nexus boot: per-run databases, a Puma subprocess on an ephemeral port, a
  # readiness poll, deterministic teardown, and redacted failure capture. It never requires a
  # pre-started server.
  #
  # The server boots in the pinned RAILS_ENV=development, so request forgery protection is active
  # and the browser CSRF leg exercises the real verification path.
  class NexusServer
    BOOT_TIMEOUT = 60
    STOP_TIMEOUT = 10
    ASSET_COMMAND_TIMEOUT = 300
    ASSET_LOCK_WARN_SECONDS = 5
    RAILS_COMMAND_TIMEOUT = 120
    DUMP_COMMAND_TIMEOUT = 20
    DROP_RESERVE_SECONDS = 30
    SECRET_PATTERN = /(sk-cybros-api-v1|sk-cybros-session-v1|rt-cybros-api-v1|dc-cybros-v1|rc-cybros-v1)-\S+/
    FAILURE_ARTIFACTS_ROOT = File.expand_path("../artifacts/failures", __dir__)
    # THE BIND (`rails server -b`): loopback, so nothing off this machine reaches a world — except
    # where a world must be reached from a Docker network the host's loopback is not on. harbor's
    # task containers run on harbor's own compose bridge (the harbor cell), never the plain driver's
    # `--network host`, so the box sets E2E_NEXUS_BIND=0.0.0.0 and names its LAN IP (10.0.0.115) as
    # the address those containers use (E2E_EVALS_HARBOR_NEXUS_HOST). The world's own URL
    # (`base_url`) stays 127.0.0.1:<port> for the harness's clients whatever the bind; Rails'
    # development host authorization admits any IP address, so the LAN address needs no
    # RAILS_DEVELOPMENT_HOSTS row.
    BIND_ENV = "E2E_NEXUS_BIND".freeze
    LOOPBACK = "127.0.0.1".freeze

    attr_reader :port, :base_url, :rho_browser_url

    def self.register_database_cleanup(server)
      @database_cleanup_owners ||= {}
      @database_cleanup_owners[server.object_id] = server

      unless @database_cleanup_at_exit
        @database_cleanup_at_exit = true
        at_exit { E2E::NexusServer.retry_registered_database_cleanup }
      end
    end

    def self.unregister_database_cleanup(server)
      @database_cleanup_owners&.delete(server.object_id)
    end

    def self.retry_registered_database_cleanup
      owners = (@database_cleanup_owners || {}).values.dup
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + RAILS_COMMAND_TIMEOUT
      owners.each do |server|
        server.stop(deadline:)
      rescue StandardError => error
        warn "Could not retry E2E database cleanup: #{error.class}: #{error.message}"
      end
    end

    def initialize(nexus_root:, port: nil, model_overrides: {}, setup_secret: nil)
      @nexus_root = nexus_root
      @model_overrides = model_overrides
      @setup_secret = setup_secret
      requested_port = port || ENV["E2E_NEXUS_PORT"]
      requested_port = Integer(requested_port) if requested_port
      @port_reservation = TCPServer.new(LOOPBACK, requested_port || 0)
      @port = @port_reservation.addr[1]
      @rho_port_reservation = TCPServer.new(LOOPBACK, 0)
      @rho_browser_url = "http://#{LOOPBACK}:#{@rho_port_reservation.addr[1]}"
      @bind = ENV.fetch(BIND_ENV, LOOPBACK)
      # Suffix every mutable per-run resource so parallel and repeated runs never share state.
      @run_id = "#{Process.pid}_#{SecureRandom.hex(8)}"
      @run_root = Dir.mktmpdir("cybros-nexus-e2e-#{@run_id}-")
      @base_url = "http://#{LOOPBACK}:#{@port}"
      @log_path = File.join(@run_root, "server.log")
      @databases_created = false
      @database_dumps_archived = false
      @mock_provider = nil
      @catalog_overlay = nil
      prepare_runtime_directories
    end

    # A DEPLOYED SYSTEM, not just a web process. Until this round the harness
    # booted `rails server` alone, so a queued InferenceRequest had no executor and the
    # fake provider had no address: a journey could create work and nothing
    # would ever run it. The order below is forced — the mock has to be
    # listening before the catalog fragment that carries its port is written,
    # and that fragment has to exist before Nexus compiles its catalog at boot.
    #
    # THE ASSET LOCK HAS TWO PHASES: exclusive while the checkout's build
    # outputs are written, shared while they are served — so K servers of one
    # checkout run side by side and a builder still waits behind every one of
    # them. A parent that built once (E2E_ASSETS_PREPARED=1) takes the shared
    # phase directly.
    def start(deadline: nil)
      @operation_deadline = deadline
      if ENV["E2E_ASSETS_PREPARED"] == "1"
        acquire_asset_lock(File::LOCK_SH)
      else
        acquire_asset_lock(File::LOCK_EX)
        prepare_assets
        acquire_asset_lock(File::LOCK_SH)
      end
      prepare_databases
      start_model_plane
      spawn_server
      wait_until_ready
    end

    # The build alone, for a parent that boots no server of its own and hands
    # K children a checkout whose assets are already written.
    def build_assets(deadline: nil)
      @operation_deadline = deadline
      acquire_asset_lock(File::LOCK_EX)
      prepare_assets
    ensure
      release_asset_lock
    end

    # The address the fake provider bound this run, for a journey that wants to
    # talk to it directly.
    def provider_base_url = @mock_provider&.base_url

    # The same frozen world every child of this run gets. A host spawned into
    # a different one would read a different database and a different catalog.
    def child_env = env

    # THE JOURNEY RUNS IN A DIFFERENT PROCESS, and two things it needs live
    # here: the per-run world (so an operator action reads the same databases)
    # and the place to put a host's log. Operator actions are not available
    # over HTTP yet — the provider console is a later round — so the handle is
    # written down instead. 0600, because the env carries this run's database
    # URLs.
    #
    # THE EXECUTION HOSTS ARE THE JOURNEY'S TO START, not this object's: a lane
    # that pins one host is the only way to assert which host ran the work, and
    # a server-owned pair would force every lane to inherit the same
    # composition.
    def operator_handle_path
      @operator_handle_path ||= run_path("runtime", "operator.json").tap do |path|
        File.write(path, JSON.generate(
          "nexus_root" => @nexus_root, "env" => env, "log_dir" => @run_root,
          "rho_browser_url" => @rho_browser_url
        ))
        File.chmod(0o600, path)
      end
    end

    # A failed run keeps redacted logs. Database dumps are an explicit local
    # opt-in and never delay the ordinary cleanup path.
    def stop(dump: false, deadline: nil)
      @teardown_deadline = deadline
      cleanup_error = nil
      begin
        terminate_server
        stop_model_plane
      rescue StandardError => error
        cleanup_error = error
      end
      release_port_reservation
      release_asset_lock

      if dump
        begin
          archive_failure_artifacts
        rescue StandardError => error
          cleanup_error ||= error
        end
      end

      begin
        drop_databases if @databases_created
      rescue StandardError => error
        cleanup_error ||= error
        begin
          # A successful journey whose drop fails still needs diagnostics;
          # a failed journey needs its new db:drop log copied as well.
          archive_failure_artifacts
        rescue StandardError => artifact_error
          warn "Could not archive E2E cleanup failure: #{artifact_error.class}: #{artifact_error.message}"
        end
      end

      raise cleanup_error if cleanup_error
    ensure
      release_port_reservation
      release_asset_lock
      unless @databases_created
        if @run_root && Dir.exist?(@run_root)
          FileUtils.remove_entry(@run_root)
        end
      end
      @teardown_deadline = nil
    end

    # Redacted server log for failure diagnostics — never leak a raw secret.
    def redacted_log(lines: 40)
      redacted_file(@log_path, lines: lines)
    end

    private

    # The child runs under Nexus's own bundle: strip every inherited bundler
    # and Ruby-loader variable (the e2e harness's) and point BUNDLE_GEMFILE
    # at Nexus, so its binstub sets up the right gems.
    # The fake provider binds first and the catalog fragment carrying its port
    # is written second, because `env` — which the server child inherits —
    # reads the overlay's directory.
    def start_model_plane
      @mock_provider = MockLLM::Server.new.start
      @catalog_overlay = CatalogOverlay.new(
        nexus_root: @nexus_root, provider_base_url: @mock_provider.base_url, model_overrides: @model_overrides
      ).install
    end

    def stop_model_plane
      @catalog_overlay&.release
      @catalog_overlay = nil
      @mock_provider&.stop
      @mock_provider = nil
    end

    def env
      cleaned = ENV.keys.grep(/\ABUNDLE/).to_h { |key| [key, nil] }
      implicit_database_urls = (
        ENV.keys.grep(/\A(?:DATABASE_URL|.+_DATABASE_URL)\z/) +
        %w[DATABASE_URL PRIMARY_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL]
      ).uniq.to_h { |key| [key, nil] }
      cleaned.merge(
        implicit_database_urls,
        "RUBYOPT" => nil,
        "RUBYLIB" => nil,
        "RAILS_ENV" => "development",
        # Development db tasks otherwise also prepare the separate test-env
        # databases. This world owns only its per-run development databases.
        "SKIP_TEST_DATABASE" => "1",
        "PORT" => @port.to_s,
        # A container on Docker Desktop's bridge reaches this loopback-bound
        # world as `host.docker.internal:<port>` (the install GROUP, the
        # evals container families), and Rails' development host
        # authorization blocks that Host header unless named here
        # (`Blocked hosts: host.docker.internal:…` was the install GROUP's
        # second world). The bind stays loopback unless E2E_NEXUS_BIND widens
        # it (`BIND_ENV`); this only allows the header.
        "RAILS_DEVELOPMENT_HOSTS" => "host.docker.internal",
        # Exercise direct localhost/LAN behavior and ignore any developer-wide
        # canonical domain override inherited by the harness.
        "BASE_URL" => nil,
        "NEXUS_SETUP_SECRET" => @setup_secret,
        "NEXUS_OAUTH_REDIRECT_URIS" => JSON.generate(["#{@rho_browser_url}/auth/callback"]),
        "NEXUS_OAUTH_ALLOW_HTTP" => "true",
        "PIDFILE" => run_path("runtime", "puma.pid"),
        "HOME" => run_path("home"),
        "XDG_CONFIG_HOME" => run_path("xdg", "config"),
        "XDG_CACHE_HOME" => run_path("xdg", "cache"),
        "XDG_STATE_HOME" => run_path("xdg", "state"),
        "XDG_RUNTIME_DIR" => run_path("runtime"),
        "TMPDIR" => run_path("tmp"),
        # The world's own Active Storage root (`config/storage.yml`'s local
        # service): under the run root, so it goes with it at `stop` and no
        # world shares a blob with another or with the developer's server.
        "RAILS_STORAGE_ROOT" => run_path("storage"),
        # The world's own Rails log (`RAILS_LOG_FILE`, nexus config/
        # environments/development.rb): one whole file under the run root,
        # never the checkout's shared `log/development.log`, which six
        # processes over two worlds rotate within minutes — so a red world's
        # dump (`failure_dump!`, every `*.log` here) holds every line the
        # world wrote. The hosts each override the row with a file of their
        # own (`NexusHosts#host_env`).
        NexusHosts::RAILS_LOG_ENV => run_path("rails.log"),
        # The device flow's published poll interval: the daemon honours the
        # number the kernel publishes (the SDK's default sleeper), so one
        # second here is what shortens its post-click lag. The token route's
        # per-identity limit is 120 a minute against 60 of polling.
        "NEXUS_DEVICE_FLOW_INTERVAL" => "1",
        # A distinct secret base keeps e2e digests off any other database.
        "SECRET_KEY_BASE" => "e2e-secret-key-base-#{@run_id}",
        # Credential writes exercise ordinary Rails encryption, with keys
        # owned by this temporary world and shared by its execution hosts.
        "ACTIVE_RECORD_ENCRYPTION__PRIMARY_KEY" => "e2e-primary-#{@run_id}",
        "ACTIVE_RECORD_ENCRYPTION__DETERMINISTIC_KEY" => "e2e-deterministic-#{@run_id}",
        "ACTIVE_RECORD_ENCRYPTION__KEY_DERIVATION_SALT" => "e2e-salt-#{@run_id}",
        "BUNDLE_GEMFILE" => File.join(@nexus_root, "Gemfile"),
        **(@catalog_overlay&.child_env || {}),
        **db_env
      )
    end

    def prepare_runtime_directories
      %w[
        home
        runtime
        tmp
        storage
        xdg/config
        xdg/cache
        xdg/state
      ].each { |path| FileUtils.mkdir_p(run_path(*path.split("/"))) }
    end

    def run_path(*parts)
      File.join(@run_root, *parts)
    end

    # The development environment's three database roles, each named per run
    # so the developer's own databases are never touched.
    def db_env
      {
        "RAILS_APP_DB_NAME" => db_name("primary"),
        "RAILS_QUEUE_DB_NAME" => db_name("queue"),
        "RAILS_CABLE_DB_NAME" => db_name("cable"),
      }
    end

    def db_name(role)
      "cybros_nexus_#{role}_e2e_#{@run_id}"
    end

    # A clean checkout has no ignored build outputs. The canonical E2E command
    # therefore prepares Nexus's frozen JS dependencies and both asset bundles
    # before booting the development server.
    def prepare_assets
      run_logged("bun_install", "bun", "install", "--frozen-lockfile", chdir: @nexus_root, timeout: ASSET_COMMAND_TIMEOUT)
      run_logged("bun_build", "bun", "run", "build", chdir: @nexus_root, timeout: ASSET_COMMAND_TIMEOUT)
      run_logged("bun_build_css", "bun", "run", "build:css", chdir: @nexus_root, timeout: ASSET_COMMAND_TIMEOUT)
    end

    # Nexus's dependency tree and build outputs live in the checkout. One
    # checkout-local flock: exclusive to build, shared to serve, held until
    # Puma stops so a build cannot rewrite files a running server serves. A
    # second call on the same open file CONVERTS the lock in place (flock
    # semantics), which is how a builder becomes a server.
    def acquire_asset_lock(mode)
      path = File.join(@nexus_root, "tmp", "e2e-assets.lock")
      FileUtils.mkdir_p(File.dirname(path))
      @asset_lock ||= File.open(path, File::RDWR | File::CREAT, 0o600)
      started = monotonic
      deadline = @operation_deadline || started + ASSET_COMMAND_TIMEOUT
      warned = false
      until @asset_lock.flock(mode | File::LOCK_NB)
        now = monotonic
        remaining = deadline - now
        raise Timeout::Error, "timed out waiting for the Nexus asset lock" unless remaining.positive?

        warned ||= warn_asset_lock_wait(mode, now - started)
        sleep [0.05, remaining].min
      end
    end

    # THE PARK IS PRINTED ONCE: a second world's boot waited ten minutes on the exclusive phase —
    # the other world held the shared phase — with nothing on the terminal. After
    # ASSET_LOCK_WARN_SECONDS one line names the phase and the way past the build; true once said.
    def warn_asset_lock_wait(mode, waited)
      return false if waited < ASSET_LOCK_WARN_SECONDS

      phase = mode == File::LOCK_EX ? "exclusive, to build the assets" : "shared, to serve them"
      warn "still waiting for the Nexus asset lock (#{phase}) after #{ASSET_LOCK_WARN_SECONDS} s: another world holds it; " \
           "E2E_ASSETS_PREPARED=1 boots a second world past the build (the flag is per boot)"
      true
    end

    def release_asset_lock
      return unless @asset_lock

      lock = @asset_lock
      @asset_lock = nil
      lock.flock(File::LOCK_UN)
    ensure
      lock&.close
    end

    def release_port_reservation
      @port_reservation&.close
      @rho_port_reservation&.close
    ensure
      @port_reservation = nil
      @rho_port_reservation = nil
    end

    # Fresh per-run databases from the committed schemas. db:prepare would
    # also run the development seeds, which found the installation and would
    # break the journey's first-boot signup leg.
    def prepare_databases
      @databases_created = true
      self.class.register_database_cleanup(self)
      # EACH ROLE'S OWN SCHEMA, named explicitly. `db:schema:load` alone left
      # the queue and cable databases empty, which nothing noticed while the
      # harness ran no executor: the moment a Solid Queue supervisor came up
      # inside Puma it died on a missing `solid_queue_recurring_tasks` and took
      # the web process with it. The four tasks ride ONE Rails boot, in order.
      run_rails("db:create", "db:schema:load:primary", "db:schema:load:queue", "db:schema:load:cable",
        label: "rails_db_prepare")
    end

    def drop_databases
      run_rails("db:drop")
      @databases_created = false
      self.class.unregister_database_cleanup(self)
    end

    # THE RED WORLD'S DUMP (`E2E::FailureDump`): the world's logs whole and redacted, its window of the Rails
    # log, and the per-turn copy — the last sealed requests read off the
    # world's own database while it still stands (the drop comes after).
    # A developer may opt into database dumps with E2E_DATABASE_DUMPS=1
    # when pg_dump is on PATH; neither condition is a suite prerequisite.
    def archive_failure_artifacts
      run_dir = File.join(FAILURE_ARTIFACTS_ROOT, @run_id)
      failure_dump!(run_dir, sealed: (@databases_created ? sealed_requests_for_dump : []))

      if database_dump_enabled? && @databases_created && !@database_dumps_archived
        File.open(File.join(run_dir, "pg_dump.log"), "w") do |log|
          %w[primary queue cable].each do |role|
            dump_database(role, run_dir: run_dir, log: log)
          end
        end
        @database_dumps_archived = true
      end
    end

    def dump_database(role, run_dir:, log:)
      name = db_name(role)
      log.puts "Dumping #{name}"
      command = [pg_dump_bin, "--format=custom", "--file", File.join(run_dir, "#{name}.dump"), name]
      status = ProcessRunner.run(
        *command, env: pg_client_env_from_base, out: log, err: [:child, :out],
        timeout: teardown_timeout(DUMP_COMMAND_TIMEOUT, reserve: DROP_RESERVE_SECONDS),
        deadline: @teardown_deadline
      )
      log.puts "Failed to dump #{name}" unless status.success?
    rescue Timeout::Error
      log.puts "Timed out dumping #{name}"
    end

    def database_dump_enabled?
      ENV["E2E_DATABASE_DUMPS"] == "1" && !pg_dump_bin.nil?
    end

    def pg_dump_bin
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
        candidate = File.join(directory, "pg_dump")
        candidate if File.file?(candidate) && File.executable?(candidate)
      end.first
    end

    def pg_client_env_from_base
      return {} unless ENV["RAILS_DB_URL_BASE"]

      uri = URI(ENV.fetch("RAILS_DB_URL_BASE"))
      {
        "PGHOST" => uri.host,
        "PGPORT" => uri.port&.to_s,
        "PGUSER" => unescape_userinfo(uri.user),
        "PGPASSWORD" => unescape_userinfo(uri.password),
      }.compact
    end

    def unescape_userinfo(value)
      URI::DEFAULT_PARSER.unescape(value) if value
    end

    def rails_bin
      File.join(@nexus_root, "bin", "rails")
    end

    def run_rails(*tasks, label: "rails_#{tasks.join("+").tr(":", "_")}")
      run_logged(
        label, rails_bin, *tasks,
        env: env, chdir: @nexus_root, timeout: teardown_timeout(RAILS_COMMAND_TIMEOUT)
      )
    end

    def run_logged(label, *command, env: {}, chdir:, timeout:)
      output = run_path("#{label}.log")
      status = File.open(output, "w") do |log|
        ProcessRunner.run(
          *command, env: env, chdir: chdir, out: log, err: [:child, :out],
          timeout: timeout, deadline: @teardown_deadline || @operation_deadline
        )
      end

      unless status.success?
        raise "#{label} failed with status #{status.exitstatus.inspect}:\n#{redacted_file(output)}"
      end
      status.success?
    rescue Timeout::Error
      raise Timeout::Error, "#{label} exceeded #{timeout}s:\n#{redacted_file(output)}"
    end

    # The dump's composition, pure over what the world holds: every `*.log`
    # under the run root (the boot, build and host logs, and each process's
    # own Rails log — `rails.log`, `jobs.rails.log`, `model_runner.rails.log`
    # — WHOLE, never a tail or a window), and the sealed documents handed
    # in. The sealed read comes separately so a harness test drives this
    # path with documents of its own.
    def failure_dump!(run_dir, sealed:)
      sources = Dir.glob(run_path("*.log")).sort.to_h { |path| [File.basename(path), path] }
      E2E::FailureDump.write(into: run_dir, sources: sources, sealed: sealed, redact: method(:redact_text))
    end

    # THE PER-TURN COPY, read off the world: the last SEALED_REQUESTS_LIMIT
    # sealed requests as the debug door serves them (`SealedRequestPresenter`),
    # each with the loop and task key (or the invocation) that sealed it and
    # the event items of the host it ran under. Read by `bin/rails runner`
    # in the world's own environment into a file; a read that fails leaves
    # its log beside the others and answers no documents.
    SEALED_REQUESTS_LIMIT = 5
    SEALED_REQUESTS = <<~RUBY.freeze
      require "json"
      limit = Integer(ARGV.fetch(1))
      ids = ContentBody.where(role: "request").where.not(model_invocation_id: nil)
        .order(created_at: :desc).limit(limit * 4).pluck(:model_invocation_id).uniq.first(limit)
      documents = ModelInvocation.where(id: ids).sort_by { |row| ids.index(row.id) }.map do |invocation|
        node = AgentRunTask.find_by(selected_model_invocation_id: invocation.id)
        agent_run = node&.agent_run
        host = if agent_run.nil? then invocation.conversation
               elsif agent_run.standalone? then agent_run
               else agent_run.conversation_turn&.conversation
               end
        events = host ? host.conversation_event_items.order(:sequence).last(200) : []
        {
          "invocation" => invocation.public_id, "sealed_at" => invocation.created_at.utc.iso8601(3),
          "model" => "\#{invocation.provider_id}/\#{invocation.model_ref}", "status" => invocation.status,
          "loop" => agent_run&.public_id, "task_key" => node&.node_key,
          "host" => (host && "\#{host.class.name} \#{host.public_id}"),
          "request" => AgentAPI::SealedRequestPresenter.call(invocation).fetch(:request),
          "events" => events.map { |item| ConversationEventItem::PublicProjection.render(item) },
        }
      end
      File.write(ARGV.fetch(0), JSON.generate(documents))
    RUBY

    def sealed_requests_for_dump
      out = run_path("runtime", "sealed_requests.json")
      run_logged("sealed_requests", rails_bin, "runner", SEALED_REQUESTS, out, SEALED_REQUESTS_LIMIT.to_s,
        env: env, chdir: @nexus_root, timeout: teardown_timeout(RAILS_COMMAND_TIMEOUT))
      JSON.parse(File.read(out, encoding: Encoding::UTF_8))
    rescue StandardError, Timeout::Error => error
      warn "the red world's sealed requests could not be read: #{error.class}: #{error.message.lines.first.to_s.strip}"
      []
    end

    # Both redactions: the harness's registered secrets and the world's
    # own token grammar.
    def redact_text(text)
      E2E::SecretHygiene.redact(text).gsub(SECRET_PATTERN, '\1-[REDACTED]')
    end

    # Logs are read as UTF-8 and scrubbed regardless of the process locale:
    # capture collection must not raise on a stray byte in a build log.
    def redacted_file(path, lines: 80)
      return "(no log)" unless File.exist?(path)

      File.readlines(path, encoding: Encoding::UTF_8)
        .last(lines).join.scrub.gsub(SECRET_PATTERN, '\1-[REDACTED]')
    end

    # The server's argv: the reserved port, the bind (`BIND_ENV`).
    def server_argv = [rails_bin, "server", "-p", @port.to_s, "-b", @bind]

    def spawn_server
      release_port_reservation
      File.open(@log_path, "w") do |log|
        @pid = Process.spawn(env, *server_argv, chdir: @nexus_root, out: log, err: log, pgroup: true)
      end
    end

    # TERM, then a bounded wait, then KILL — teardown never hangs on a stuck server.
    def terminate_server
      return unless @pid

      ProcessRunner.terminate(
        @pid,
        timeout: teardown_timeout(STOP_TIMEOUT, allow_zero: true),
        deadline: @teardown_deadline
      )
    ensure
      @pid = nil
    end

    def teardown_timeout(maximum, reserve: 0, allow_zero: false)
      return maximum unless @teardown_deadline

      available = @teardown_deadline - monotonic - reserve
      return [available, maximum].min if available.positive?
      return 0 if allow_zero

      raise Timeout::Error, "E2E teardown deadline exhausted"
    end

    def wait_until_ready
      deadline = [monotonic + BOOT_TIMEOUT, @operation_deadline].compact.min
      loop do
        raise "Nexus did not become ready in #{BOOT_TIMEOUT}s:\n#{redacted_log}" if monotonic > deadline

        # ASSIGN, THEN TEST. Written as `raise_server_exit(status) if (status =
        # server_exit_status)` the argument parses before the modifier's
        # assignment has introduced the local, so `status` reads as a method
        # call — and the line raises NameError instead of reporting the exit.
        # It could only ever have worked while the condition was false, which
        # is to say it worked until a server actually died.
        exited = server_exit_status
        raise_server_exit(exited) if exited

        if healthy?
          exited = server_exit_status
          raise_server_exit(exited) if exited
          return
        end

        sleep 0.5
      end
    end

    def server_exit_status
      return unless @pid

      result = Process.wait2(@pid, Process::WNOHANG)
      return unless result

      @pid = nil
      result.last
    rescue Errno::ECHILD
      @pid = nil
      :unknown
    end

    def raise_server_exit(status)
      detail = status == :unknown ? "unknown status" : "status #{status.exitstatus.inspect}"
      raise "Nexus exited before readiness with #{detail}:\n#{redacted_log}"
    end

    def healthy?
      uri = URI("#{@base_url}/up")
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      response.is_a?(Net::HTTPSuccess)
    rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, EOFError
      false
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
