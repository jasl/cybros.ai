require "test_helper"
require "rbconfig"
require "socket"
require "tmpdir"
require "timeout"
require "support/nexus_hosts"

class NexusHostsHarnessTest < Minitest::Test
  def test_a_previous_runner_marker_cannot_release_the_current_start
    with_runner do |hosts, listener|
      File.write(hosts.log_path(:runner), "previous boot: #{E2E::NexusHosts::RUNNER_READY}\n")
      starter = start_runner(hosts)
      control = await_boot(listener)

      assert_nil starter.join(0.2), "the current runner has not announced readiness"

      control.puts "ready"
      assert starter.join(3), "the current runner's marker should release start"
      assert_equal [:ready, hosts], starter.value
      assert_equal 2, File.read(hosts.log_path(:runner)).scan(E2E::NexusHosts::RUNNER_READY).size
    ensure
      starter&.kill&.join
      control&.close
    end
  end

  def test_runner_exit_before_readiness_reports_the_failure_and_allows_retry
    with_runner do |hosts, listener|
      starter = start_runner(hosts)
      control = await_boot(listener)
      control.puts "exit"

      assert starter.join(3), "a dead runner should fail without waiting for the readiness deadline"
      outcome, error = starter.value
      assert_equal :error, outcome
      assert_match(/model runner exited before announcing itself/, error.message)
      assert_match(/exit 17/, error.message)
      assert_includes error.message, "intentional startup failure"
      control.close

      starter = start_runner(hosts)
      control = await_boot(listener)
      control.puts "ready"
      assert starter.join(3), "a failed start should leave the host restartable"
      assert_equal [:ready, hosts], starter.value
    ensure
      starter&.kill&.join
      control&.close
    end
  end

  private

    def with_runner
      Dir.mktmpdir do |root|
        listener = TCPServer.new("127.0.0.1", 0)
        FileUtils.mkdir_p(File.join(root, "bin"))
        runner = File.join(root, "bin", "model_runner")
        File.write(runner, <<~RUBY)
          #!#{RbConfig.ruby}
          require "socket"
          $stdout.sync = true
          control = TCPSocket.new("127.0.0.1", ENV.fetch("RUNNER_TEST_PORT"))
          control.puts "booted"
          if control.gets&.chomp == "exit"
            warn "intentional startup failure"
            exit 17
          end
          puts #{E2E::NexusHosts::RUNNER_READY.inspect}
          sleep
        RUBY
        File.chmod(0o755, runner)
        hosts = E2E::NexusHosts.new(
          nexus_root: root, env: { "RUNNER_TEST_PORT" => listener.addr[1].to_s }, log_dir: root
        )
        yield hosts, listener
      ensure
        # Reap an exited fixture even when a broken readiness wait leaves it behind.
        runner_pid = hosts&.instance_variable_get(:@hosts)&.fetch(:runner)&.pid
        Process.waitpid(runner_pid, Process::WNOHANG) if runner_pid
        hosts&.stop
        listener&.close
      end
    end

    def start_runner(hosts)
      Thread.new do
        [:ready, hosts.start(:runner)]
      rescue StandardError => error
        [:error, error]
      end
    end

    def await_boot(listener)
      Timeout.timeout(3) do
        control = listener.accept
        assert_equal "booted\n", control.gets
        control
      end
    end
end
