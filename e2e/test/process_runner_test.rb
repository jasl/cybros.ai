require "test_helper"
require "minitest/mock"
require "rbconfig"
require "tmpdir"
require_relative "../support/process_registry"
require_relative "../support/process_runner"

class ProcessRunnerTest < Minitest::Test
  def test_returns_the_child_status
    status = E2E::ProcessRunner.run(RbConfig.ruby, "-e", "exit 7")

    assert_equal 7, status.exitstatus
  end

  def test_timeout_terminates_the_owned_process_group
    Dir.mktmpdir do |root|
      pid_file = File.join(root, "pids")
      script = <<~RUBY
        trap("TERM") {}
        child = Process.spawn(#{RbConfig.ruby.inspect}, "-e", 'trap("TERM") {}; sleep 60')
        File.write(ARGV.fetch(0), [Process.pid, child].join("\\n"))
        Process.wait(child)
      RUBY

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Timeout::Error) do
        E2E::ProcessRunner.run(RbConfig.ruby, "-e", script, pid_file, timeout: 1)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_operator elapsed, :<, 1.5
      File.readlines(pid_file, chomp: true).each do |pid|
        assert_process_exits(Integer(pid))
      end
    end
  end

  def test_signal_exit_drains_a_registered_independent_process_group
    Dir.mktmpdir do |root|
      pid_file = File.join(root, "pid")
      support_root = File.expand_path("../support", __dir__)
      script = <<~RUBY
        $LOAD_PATH.unshift(ARGV.fetch(0))
        require "process_registry"
        require "rbconfig"

        ready_file = "\#{ARGV.fetch(1)}.ready"
        child = E2E::ProcessRegistry.spawn(
          RbConfig.ruby, "-e",
          'trap("TERM", "IGNORE"); File.write(ARGV.fetch(0), "ready"); sleep 60',
          ready_file,
          out: File::NULL, err: File::NULL, pgroup: true
        )
        File.write(ARGV.fetch(1), child)
        sleep 0.01 until File.exist?(ready_file)
        Process.kill("TERM", Process.pid)
      RUBY

      status = E2E::ProcessRunner.run(
        RbConfig.ruby, "-e", script, support_root, pid_file, timeout: 5
      )

      assert_predicate status, :signaled?
      assert_process_group_exits(Integer(File.read(pid_file)))
    end
  end

  def test_signal_exit_drains_two_stuck_process_groups_within_one_sweep_budget
    Dir.mktmpdir do |root|
      pid_file = File.join(root, "pids")
      support_root = File.expand_path("../support", __dir__)
      script = <<~RUBY
        $LOAD_PATH.unshift(ARGV.fetch(0))
        require "process_registry"
        require "rbconfig"

        children = 2.times.map do |index|
          ready_file = "\#{ARGV.fetch(1)}.\#{index}.ready"
          E2E::ProcessRegistry.spawn(
            RbConfig.ruby, "-e",
            'trap("TERM", "IGNORE"); File.write(ARGV.fetch(0), "ready"); sleep 60',
            ready_file,
            out: File::NULL, err: File::NULL, pgroup: true
          )
        end
        File.write(ARGV.fetch(1), children.join("\\n"))
        sleep 0.01 until 2.times.all? { |index| File.exist?("\#{ARGV.fetch(1)}.\#{index}.ready") }
        Process.kill("TERM", Process.pid)
      RUBY

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = E2E::ProcessRunner.run(
        RbConfig.ruby, "-e", script, support_root, pid_file, timeout: 4
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      pids = File.readlines(pid_file, chomp: true).map { |pid| Integer(pid) }

      assert_predicate status, :signaled?
      assert_operator elapsed, :<, 3.5
      pids.each { |pid| assert_process_group_exits(pid) }
    ensure
      pids&.each { |pid| terminate_process_group(pid) }
    end
  end

  def test_normal_termination_unregisters_the_process_group
    pid = E2E::ProcessRegistry.spawn(
      RbConfig.ruby, "-e", "sleep 60",
      out: File::NULL, err: File::NULL, pgroup: true
    )

    E2E::ProcessRegistry.terminate(pid)
    pid = nil
    calls = []
    E2E::ProcessRunner.stub(:terminate, ->(candidate, **) { calls << candidate }) do
      E2E::ProcessRegistry.drain
    end

    assert_empty calls
  ensure
    E2E::ProcessRegistry.terminate(pid) if pid
  end

  private

    def assert_process_exits(pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        Process.kill(0, pid)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      rescue Errno::ESRCH
        return
      end

      flunk "expected process #{pid} to exit"
    end

    def assert_process_group_exits(pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        Process.kill(0, -pid)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      rescue Errno::ESRCH
        return
      end

      flunk "expected process group #{pid} to exit"
    end

    def terminate_process_group(pid)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end
end
