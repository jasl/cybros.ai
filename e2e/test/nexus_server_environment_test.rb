require "test_helper"
require "rbconfig"
require "stringio"
require "minitest/mock"

class NexusServerEnvironmentTest < Minitest::Test
  def test_child_environment_uses_request_origin_and_clears_implicit_database_urls
    with_environment(
      "BASE_URL" => "https://developer.example",
      "RAILS_DB_URL_BASE" => "postgresql://database.example",
      "DATABASE_URL" => "postgresql://wrong.example/primary",
      "PRIMARY_DATABASE_URL" => "postgresql://wrong.example/primary-role",
      "REPORTING_DATABASE_URL" => "postgresql://wrong.example/reporting"
    ) do
      server = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
      child = server.send(:env)
      effective = ENV.to_h.merge(child.compact)
      child.each { |key, value| effective.delete(key) if value.nil? }

      assert_equal "postgresql://database.example", effective.fetch("RAILS_DB_URL_BASE")
      refute effective.key?("DATABASE_URL")
      refute effective.key?("PRIMARY_DATABASE_URL")
      refute effective.key?("REPORTING_DATABASE_URL")
      refute effective.key?("BASE_URL")
      assert_match(/\Acybros_nexus_primary_e2e_\d+_[0-9a-f]{16}\z/, effective.fetch("RAILS_APP_DB_NAME"))
      # The world's Active Storage root is the run's own, so it is removed
      # with the run root at `stop` and shared with no other world.
      assert_equal server.send(:run_path, "storage"), effective.fetch("RAILS_STORAGE_ROOT")
      # The world's Rails log is its own whole file under the run root, so
      # the dump's glob copies it and no checkout-wide rotation loses it.
      assert_equal server.send(:run_path, "rails.log"), effective.fetch("RAILS_LOG_FILE")
      assert_equal "RAILS_LOG_FILE", E2E::NexusHosts::RAILS_LOG_ENV
    ensure
      server&.stop
    end
  end

  # EACH HOST'S OWN RAILS LOG: the jobs and runner processes are spawned
  # with the world's env, the one row overridden with a file each beside
  # their stdout logs — three whole files in the run root, all picked up
  # by the dump's `*.log` glob.
  def test_each_host_is_spawned_with_its_own_rails_log_under_the_run_root
    server = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
    run_root = server.send(:run_path)
    hosts = E2E::NexusHosts.new(nexus_root: E2E::NEXUS_ROOT, env: server.send(:env), log_dir: run_root)

    assert_equal File.join(run_root, "jobs.rails.log"), hosts.rails_log_path(:jobs)
    assert_equal File.join(run_root, "model_runner.rails.log"), hosts.rails_log_path(:runner)
    %i[jobs runner].each do |name|
      host = hosts.instance_variable_get(:@hosts).fetch(name)
      env = hosts.send(:host_env, host)
      assert_equal hosts.rails_log_path(name), env.fetch("RAILS_LOG_FILE"), "#{name}: its own file, not the web's"
      assert_equal server.send(:env).except("RAILS_LOG_FILE"), env.except("RAILS_LOG_FILE"), "#{name}: the world's env otherwise"
      refute_equal hosts.log_path(name), hosts.rails_log_path(name), "#{name}: the Rails log is not the stdout log"
    end
  ensure
    server&.stop
  end

  def test_reserves_its_port_until_the_owned_server_is_spawned
    first = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
    second = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)

    refute_equal first.port, second.port
    assert_raises(Errno::EADDRINUSE) { TCPServer.new("127.0.0.1", first.port) }
  ensure
    first&.stop
    second&.stop
  end

  # THE BIND KNOB (the harbor cell): loopback unless E2E_NEXUS_BIND widens it — the box binds
  # 0.0.0.0 so harbor's task containers on their compose bridge reach the world by the LAN IP — and
  # the world's own URL stays loopback whatever the bind.
  def test_the_server_binds_loopback_unless_the_bind_knob_widens_it
    server = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
    assert_equal [server.send(:rails_bin), "server", "-p", server.port.to_s, "-b", "127.0.0.1"], server.send(:server_argv)
    assert_equal "http://127.0.0.1:#{server.port}", server.base_url
    with_environment("E2E_NEXUS_BIND" => "0.0.0.0") do
      wide = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
      assert_equal ["-b", "0.0.0.0"], wide.send(:server_argv).last(2)
      assert_equal "http://127.0.0.1:#{wide.port}", wide.base_url, "the world's own URL stays loopback whatever the bind"
    ensure
      wide&.stop
    end
    assert_equal "E2E_NEXUS_BIND", E2E::NexusServer::BIND_ENV
  ensure
    server&.stop
  end

  def test_database_drop_failure_fails_cleanup
    server = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
    drop_attempts = 0
    server.define_singleton_method(:run_rails) do |*tasks, **|
      if tasks == ["db:drop"]
        drop_attempts += 1
        raise "drop exploded" if drop_attempts == 1
      end
    end
    server.define_singleton_method(:archive_failure_artifacts) { }
    server.send(:prepare_databases)

    error = assert_raises(RuntimeError) { server.stop }

    assert_equal "drop exploded", error.message
    E2E::NexusServer.retry_registered_database_cleanup
    assert_equal 2, drop_attempts
  end

  def test_registered_database_cleanup_gets_a_fresh_bounded_deadline
    captured_deadline = nil
    server = Object.new
    server.define_singleton_method(:stop) { |deadline: nil| captured_deadline = deadline }
    before_retry = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    E2E::NexusServer.register_database_cleanup(server)

    E2E::NexusServer.retry_registered_database_cleanup

    after_retry = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    refute_nil captured_deadline
    assert_operator captured_deadline, :>=, before_retry + E2E::NexusServer::RAILS_COMMAND_TIMEOUT
    assert_operator captured_deadline, :<=, after_retry + E2E::NexusServer::RAILS_COMMAND_TIMEOUT
  ensure
    E2E::NexusServer.unregister_database_cleanup(server) if server
  end

  def test_process_exit_retries_registered_database_cleanup
    Dir.mktmpdir do |root|
      marker = File.join(root, "retried")
      server_file = File.expand_path("../support/nexus_server", __dir__)
      script = <<~RUBY
        require #{server_file.inspect}

        server = E2E::NexusServer.new(nexus_root: ARGV.fetch(1))
        drop_attempts = 0
        server.define_singleton_method(:run_rails) do |*tasks, **|
          if tasks == ["db:drop"]
            drop_attempts += 1
            if drop_attempts == 1
              raise "drop exploded"
            else
              File.write(ARGV.fetch(0), "retried")
            end
          end
        end
        server.define_singleton_method(:archive_failure_artifacts) { }
        server.send(:prepare_databases)
        run_root = server.instance_variable_get(:@run_root)

        begin
          server.stop
        rescue RuntimeError
          nil
        end

        raise "run root removed before cleanup retry" unless Dir.exist?(run_root)
      RUBY

      status = E2E::ProcessRunner.run(
        RbConfig.ruby, "-e", script, marker, E2E::NEXUS_ROOT,
        timeout: 5
      )

      assert_predicate status, :success?
      assert_equal "retried", File.read(marker)
    end
  end

  def test_inline_fallback_cleans_up_when_start_fails
    server = Struct.new(:stopped) do
      def start
        raise "boot exploded"
      end

      def stop
        self.stopped = true
      end
    end.new(false)

    E2E::NexusServer.stub(:new, server) do
      error = assert_raises(RuntimeError) { E2E.inline_server }

      assert_equal "boot exploded", error.message
    end

    assert server.stopped
    assert_nil E2E.instance_variable_get(:@inline_server)
  ensure
    E2E.shutdown
  end

  def test_each_world_owns_its_encryption_keys_and_keeps_them_stable_for_hosts
    keys = %w[ACTIVE_RECORD_ENCRYPTION__PRIMARY_KEY ACTIVE_RECORD_ENCRYPTION__DETERMINISTIC_KEY
              ACTIVE_RECORD_ENCRYPTION__KEY_DERIVATION_SALT]
    with_environment(keys.to_h { |key| [key, "developer-key"] }) do
      first = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
      second = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
      keys.each do |key|
        value = first.child_env.fetch(key)
        refute_equal "developer-key", value
        assert_equal value, first.child_env.fetch(key)
        refute_equal value, second.child_env.fetch(key)
      end
    ensure
      first&.stop
      second&.stop
    end
  end

  def test_failure_dump_is_explicit_and_uses_pg_dump_from_path
    captured_command = nil
    pg_dump = nil
    status = Struct.new(:success?).new(true)
    runner = lambda do |*command, **_options|
      captured_command = command
      status
    end

    Dir.mktmpdir do |bin|
      pg_dump = File.join(bin, "pg_dump")
      File.write(pg_dump, "#!/bin/sh\n")
      File.chmod(0o700, pg_dump)
      with_environment("E2E_DATABASE_DUMPS" => "1", "PATH" => bin) do
        server = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
        assert server.send(:database_dump_enabled?)
        Dir.mktmpdir do |run_dir|
          E2E::ProcessRunner.stub(:run, runner) do
            server.send(:dump_database, "primary", run_dir: run_dir, log: StringIO.new)
          end
        end
      ensure
        server&.stop
      end
    end

    assert_equal pg_dump, captured_command.first
  end

  def test_failure_dump_is_disabled_by_default
    server = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)

    refute server.send(:database_dump_enabled?)
  ensure
    server&.stop
  end

  def test_asset_lock_excludes_a_parallel_process
    server = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
    server.send(:acquire_asset_lock, File::LOCK_EX)
    lock_path = server.instance_variable_get(:@asset_lock).path
    probe = <<~RUBY
      lock = File.open(ARGV.fetch(0), File::RDWR | File::CREAT, 0o600)
      exit(lock.flock(File::LOCK_EX | File::LOCK_NB) ? 1 : 0)
    RUBY

    status = E2E::ProcessRunner.run(RbConfig.ruby, "-e", probe, lock_path, timeout: 2)

    assert_predicate status, :success?
  ensure
    server&.stop
  end

  # THE LOCK PARKS OUT LOUD: W1's second boot waited ten minutes on the exclusive phase with nothing
  # printed. After five seconds of waiting one line names the mode and the way past the build —
  # once, however long the wait runs; the clock is stubbed, nothing sleeps long.
  def test_a_waiting_asset_lock_warns_once_after_five_seconds
    server = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
    server.send(:acquire_asset_lock, File::LOCK_EX)
    second = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
    base = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ticks = 0
    second.define_singleton_method(:monotonic) { base + (ticks += 3) }
    second.instance_variable_set(:@operation_deadline, base + 30)

    _out, err = capture_io { assert_raises(Timeout::Error) { second.send(:acquire_asset_lock, File::LOCK_EX) } }
    assert_equal 1, err.scan("Nexus asset lock").size, "one line, however many polls"
    assert_includes err, "still waiting for the Nexus asset lock (exclusive, to build the assets) after 5 s: another world holds it; " \
                         "E2E_ASSETS_PREPARED=1 boots a second world past the build (the flag is per boot)"
    assert_equal 5, E2E::NexusServer::ASSET_LOCK_WARN_SECONDS
  ensure
    second&.singleton_class&.remove_method(:monotonic)
    second&.stop
    server&.stop
  end

  # THE CHEAP TWO-NEXUS TEST: a server that built (exclusive) and now serves
  # (shared) still keeps a builder out, and lets a second server in. Booting
  # two Pumas here is not cheap; the group run itself is that proof.
  def test_a_serving_run_holds_the_asset_lock_shared
    server = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
    server.send(:acquire_asset_lock, File::LOCK_EX)
    server.send(:acquire_asset_lock, File::LOCK_SH)
    lock_path = server.instance_variable_get(:@asset_lock).path
    probe = <<~RUBY
      lock = File.open(ARGV.fetch(0), File::RDWR | File::CREAT, 0o600)
      exit(lock.flock(File::LOCK_EX | File::LOCK_NB) ? 1 : 0)
    RUBY

    status = E2E::ProcessRunner.run(RbConfig.ruby, "-e", probe, lock_path, timeout: 2)
    assert_predicate status, :success?, "a builder got the exclusive lock past a serving run"

    second = E2E::NexusServer.new(nexus_root: E2E::NEXUS_ROOT)
    second.instance_variable_set(:@operation_deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2)
    second.send(:acquire_asset_lock, File::LOCK_SH)
    assert second.instance_variable_get(:@asset_lock), "a second server did not join the shared phase"
  ensure
    second&.stop
    server&.stop
  end

  private

    def with_environment(values)
      previous = values.to_h { |key, _value| [key, ENV[key]] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end
end
