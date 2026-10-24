require "test_helper"
require "rho/env/tools/terminal"

class TerminalTest < Minitest::Test
  include RunnerTest::Helpers

  class Gate < Rho::Env::ClaimRealtime
    attr_accessor :permitted
    def initialize = @permitted = true
    def allowed? = @permitted
  end

  def test_interactive_shell_ctrl_c_and_cleanup_of_its_foreground_child
    with_tool_env do |env, root|
      shell = Rho::Env::Tools::Terminal::Shell.new(root: root)
      context = Rho::Env::ExecutionContext.current
      input = "printf 'READY:%s\\n' $$\n"
      assert_equal input.bytesize, shell.write(input, context: context)
      output = read_until(shell, /READY:(\d+)/)
      pid = output.match(/READY:(\d+)/)[1].to_i
      shell.write("sleep 30\n", context: context)
      sleep 0.1
      shell.write("\x03", context: context)
      shell.write("printf 'RESUMED:%s\\n' $$\n", context: context)
      assert_match(/RESUMED:#{pid}/, read_until(shell, /RESUMED:#{pid}/))
      shell.write("set +H\n", context: context)
      shell.write("sleep 30 & printf 'CHILD:%s\\n' $!; wait\n", context: context)
      child = read_until(shell, /CHILD:(\d+)/).match(/CHILD:(\d+)/)[1].to_i
      shell.cancel
      shell.close
      assert_process_gone(pid)
      assert_process_gone(child)
      shell.cancel
    ensure
      shell&.close
    end
  end

  def test_shell_exit_cleans_its_background_job
    with_tool_env do |env, root|
      shell = Rho::Env::Tools::Terminal::Shell.new(root: root)
      context = Rho::Env::ExecutionContext.current
      shell.write("set +H\nsleep 30 & printf 'CHILD:%s\\n' $!\n", context: context)
      child = read_until(shell, /CHILD:(\d+)/).match(/CHILD:(\d+)/)[1].to_i
      shell.write("exit\n", context: context)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until shell.read.nil?
        flunk "shell did not exit" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.01
      end
      shell.close
      assert_process_gone(child)
    ensure
      shell&.close
    end
  end

  def test_stop_kills_a_foreground_job_that_ignores_hangup
    with_tool_env do |_env, root|
      shell = Rho::Env::Tools::Terminal::Shell.new(root: root)
      shell.write(%(sh -c 'trap "" HUP; echo CHILD:$$; exec sleep 30'\n), context: Rho::Env::ExecutionContext.current)
      child = read_until(shell, /CHILD:(\d+)/).match(/CHILD:(\d+)/)[1].to_i
      shell.close
      assert_process_gone(child)
    ensure
      shell&.close
    end
  end

  def test_stop_releases_a_flooded_pty_before_reaping_under_async
    # Isolate the native wait: a regression must fail this test, not freeze
    # the suite's Ruby scheduler before its timeout can fire.
    source = <<~RUBY
      require "rho/env"
      require "rho/env/tools/terminal"
      require "async"
      Async do
        shell = Rho::Env::Tools::Terminal::Shell.new(root: Dir.pwd)
        shell.write("yes FLOOD\\n", context: Rho::Env::ExecutionContext.new)
        sleep 0.3
        shell.close
        puts "closed"
      end.wait
    RUBY
    io = IO.popen([RbConfig.ruby, "-Ilib", "-e", source], err: [:child, :out])
    assert io.wait_readable(5), "flooded terminal cleanup did not finish"
    assert_equal "closed\n", io.gets
  ensure
    if io
      begin
        Process.kill("KILL", io.pid)
      rescue Errno::ESRCH
        nil
      end
      io.close
    end
  end

  def test_shell_returns_partial_write_count_when_permission_expires
    with_tool_env do |_env, root|
      shell = Rho::Env::Tools::Terminal::Shell.new(root: root)
      gate = Gate.new
      context = Rho::Env::ExecutionContext.new(realtime: gate)
      writer = shell.instance_variable_get(:@writer)
      original = writer.method(:write_nonblock)
      writer.define_singleton_method(:write_nonblock) do |bytes, exception:|
        count = original.call(bytes.byteslice(0, 2), exception: exception)
        gate.permitted = false
        count
      end
      assert_equal 2, shell.write("echo should-not-run\n", context: context)
    ensure
      shell&.close
    end
  end

  private

    def read_until(shell, pattern)
      output = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until output.match?(pattern)
        bytes = shell.read
        output << bytes if bytes && bytes != :wait_readable
        flunk "terminal did not respond: #{output.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.01
      end
      output
    end
end
