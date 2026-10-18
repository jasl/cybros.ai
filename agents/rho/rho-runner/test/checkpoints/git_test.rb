require "test_helper"
require "rbconfig"
require "timeout"

class CheckpointGitTest < Minitest::Test
  include RunnerTest::Helpers

  Context = Rho::Runner::ExecutionContext
  Git = Rho::Runner::Checkpoints::Git

  def setup
    @directory = Dir.mktmpdir("rho-checkpoint-wait")
    @ready = File.join(@directory, "ready")
    @git = Git.new(binary: RbConfig.ruby, git_dir: @directory, work_tree: @directory)
    @script = "File.write(#{@ready.dump}, Process.pid.to_s); sleep 60"
  end

  def teardown
    @context&.cancel
    @worker&.join(3)
    FileUtils.rm_rf(@directory) if @directory
  end

  def test_cancel_remains_cancellation_and_reaps_the_owned_command
    @context = Context.new
    @worker = Thread.new do
      Context.with(@context) { @git.call("-e", @script, deadline: clock + 30) }
    rescue Context::Cancelled
      :cancelled
    end
    Timeout.timeout(5) { sleep 0.01 until File.file?(@ready) && !File.read(@ready).empty? }
    @context.cancel

    assert @worker.join(3)
    assert_equal :cancelled, @worker.value
    assert_process_gone(Integer(File.read(@ready)))
    assert @git.call("-e", "exit 0", deadline: clock + 5).ok?
  end

  def test_deadline_still_kills_and_reaps_the_owned_command
    assert_raises(Git::TimedOut) do
      @git.call("-e", @script, deadline: clock + 1)
    end

    assert File.file?(@ready), "the command ran before its deadline"
    assert_process_gone(Integer(File.read(@ready)))
    assert_equal 7, @git.call("-e", "exit 7", deadline: clock + 5).status.exitstatus
  end

  private

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
