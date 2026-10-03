require "test_helper"
require "digest"

# Behavioral coverage for the bash tool port: process-group execution,
# merged-stream ordering, tail truncation + spill, wall-clock timeout, and
# the post-exit drain grace (pi#5303).
class RhoRunnerToolsBashTest < Minitest::Test
  include RunnerTest::Helpers

  def test_basic_echo
    with_tool_env do |env, _root|
      result = call_bash(env, "echo hello")

      refute result.is_error
      assert_equal "hello", result.content
      assert_equal({ "exit_status" => 0 }, result.structured_content)
    end
  end

  def test_stdout_and_stderr_are_merged_in_arrival_order
    with_tool_env do |env, _root|
      result = call_bash(env, "echo one; echo two >&2; echo three")

      refute result.is_error
      assert_equal "one\ntwo\nthree", result.content
    end
  end

  def test_nonzero_exit_is_an_error_that_still_carries_the_output
    with_tool_env do |env, _root|
      result = call_bash(env, "echo boom; exit 3")

      assert result.is_error
      assert_includes result.content, "boom"
      assert_includes result.content, "Command exited with code 3"
      assert_equal 3, result.structured_content.fetch("exit_status")
    end
  end

  def test_timeout_kills_the_process_group_and_reports_the_timeout
    with_tool_env do |env, root|
      started = monotonic
      result = call_bash(
        env,
        "ps -o pgid= -p $$ | tr -d ' ' > pid; echo started; sleep 30",
        "timeout" => 1
      )
      elapsed = monotonic - started

      assert result.is_error
      assert_includes result.content, "started"
      assert_includes result.content, "Command timed out after 1 seconds"
      refute result.structured_content&.key?("exit_status")
      assert_operator elapsed, :<, 3

      pgid = File.read(File.join(root, "pid")).to_i
      assert_operator pgid, :>, 0
      assert process_group_gone?(pgid), "expected process group #{pgid} to be killed"
    end
  end

  def test_signal_termination_has_no_exit_status
    with_tool_env do |env, _root|
      result = call_bash(env, "kill -TERM $$")

      refute result.is_error
      refute result.structured_content&.key?("exit_status")
    end
  end

  def test_detached_grandchild_does_not_stall_the_result
    with_tool_env do |env, _root|
      started = monotonic
      result = call_bash(env, "sleep 20 & echo done")
      elapsed = monotonic - started

      refute result.is_error
      assert_equal "done", result.content
      assert_operator elapsed, :<, 5
    end
  end

  def test_normal_success_reaps_silent_background_children_before_returning
    pgid = nil
    with_tool_env do |env, root|
      result = call_bash(
        env,
        "ps -o pgid= -p $$ | tr -d ' ' > pgid; sleep 30 >/dev/null 2>&1 & echo done"
      )
      pgid = File.read(File.join(root, "pgid")).to_i

      refute result.is_error
      assert_equal "done", result.content
      assert_operator pgid, :>, 0
      assert process_group_gone?(pgid), "expected successful bash process group #{pgid} to be reaped"
    end
  ensure
    if pgid&.positive?
      begin
        Process.kill("KILL", -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end

  def test_flooding_orphan_cannot_stall_the_drain_past_the_deadline
    with_tool_env do |env, _root|
      # The shell exits immediately but leaves an orphan writing with
      # sub-grace gaps; the wall clock must still end the call and kill the
      # orphan's group (pi keeps its timeout armed across the whole drain).
      started = monotonic
      result = call_bash(env, "while :; do echo tick; sleep 0.05; done & exit 0", "timeout" => 1)
      elapsed = monotonic - started

      assert result.is_error
      assert_includes result.content, "Command timed out after 1 seconds"
      assert_operator elapsed, :<, 4
    end
  end

  def test_default_timeout_comes_from_the_env
    with_tool_env(bash_timeout_seconds: 1) do |env, _root|
      # No "timeout" argument: the default wall-clock timeout (carried by ToolEnv) must bound
      # the call.
      started = monotonic
      result = call_bash(env, "sleep 30")
      elapsed = monotonic - started

      assert result.is_error
      assert_includes result.content, "Command timed out after 1 seconds"
      assert_operator elapsed, :<, 4
    end
  end

  def test_large_output_spills_the_full_stream_and_returns_the_tail
    with_tool_env do |env, _root|
      result = call_bash(env, "seq 1 20000")

      refute result.is_error
      assert result.content.start_with?("18001\n"), "expected the tail, got: #{result.content[0, 40].inspect}"
      assert_includes result.content, "[Showing lines 18001-20000 of 20000. Full output: "

      details = result.structured_content
      spill_path = details.fetch("spill_path")
      assert_includes result.content, spill_path
      assert_equal env.artifacts_dir, File.dirname(spill_path)
      refute spill_path.start_with?("#{env.root}/"),
        "the spill is rho's bookkeeping, never a file in the person's tree (H-4): #{spill_path}"
      assert_equal (1..20_000).map { |n| "#{n}\n" }.join, File.read(spill_path, mode: "rb")
      # THE SPILL IS A CAPTURE: the same file the footer names,
      # handed to the run beside the sentence — a client fetches the whole
      # output the model was shown the tail of.
      assert_equal [spill_path], result.files
      assert details.dig("truncation", "truncated")
      assert_equal 20_000, details.dig("truncation", "total_lines")
    end
  end

  # A SPILL IS NAMED BY ITS CONTENT: the footer names the spill's path, so a random name would make
  # every re-run of the same failing suite read as a new result. The run streams into a temporary
  # file and renames it to the digest of what it holds.
  def test_identical_over_limit_runs_answer_byte_identical_results_with_one_content_named_spill
    with_tool_env do |env, _root|
      first = call_bash(env, "seq 1 20000")
      second = call_bash(env, "seq 1 20000")

      assert_equal first.content, second.content, "the same output reads as the same result"
      spill = first.structured_content.fetch("spill_path")
      digest = Digest::SHA256.hexdigest((1..20_000).map { |n| "#{n}\n" }.join)
      assert_equal File.join(env.artifacts_dir, "bash-#{digest[0, 16]}.log"), spill
      assert_equal spill, second.structured_content.fetch("spill_path")
      assert_equal [File.basename(spill)], Dir.children(env.artifacts_dir), "one spill, no temporary left behind"
      assert_equal [spill], second.files
    end
  end

  def test_empty_output_renders_the_placeholder
    with_tool_env do |env, _root|
      result = call_bash(env, "true")

      refute result.is_error
      assert_equal "(no output)", result.content
      assert_equal({ "exit_status" => 0 }, result.structured_content)
    end
  end

  def test_commands_run_in_the_env_root
    with_tool_env do |env, root|
      result = call_bash(env, "pwd")

      refute result.is_error
      assert_equal File.realpath(root), File.realpath(result.content)
    end
  end

  def test_rejects_a_non_positive_timeout
    with_tool_env do |env, _root|
      result = call_bash(env, "echo hi", "timeout" => 0)

      assert result.is_error
      assert_includes result.content, "Invalid timeout"
    end
  end

  def test_rejects_a_timeout_above_the_kernel_safe_ceiling
    with_tool_env do |env, _root|
      result = call_bash(env, "echo must-not-run", "timeout" => Rho::Runner::Tools::Bash::MAX_TIMEOUT_SECONDS + 1)

      assert result.is_error
      assert_includes result.content, Rho::Runner::Tools::Bash::MAX_TIMEOUT_SECONDS.to_s
      assert_equal Rho::Runner::Tools::Bash::MAX_TIMEOUT_SECONDS,
                   Rho::Runner::Tools::Bash::SCHEMA.dig("properties", "timeout", "maximum")
    end
  end

  def test_multibyte_output_survives
    with_tool_env do |env, _root|
      result = call_bash(env, "printf '日本語 héllo wörld\\n'")

      refute result.is_error
      assert_equal "日本語 héllo wörld", result.content
    end
  end

  def test_invalid_utf8_is_scrubbed_not_fatal
    with_tool_env do |env, _root|
      result = call_bash(env, "printf 'a\\xffb\\n'")

      refute result.is_error
      assert result.content.valid_encoding?
      assert_includes result.content, "a"
      assert_includes result.content, "b"
    end
  end


  # WHAT THE COMMAND HAS SAID SO FAR reaches a watcher while it runs
  # (executor.md "Progress"): under the pool — whose wait is where the
  # frame is posted, on the reactor's side, never from the handler — a
  # command printing over time posts its rolling tail before it answers,
  # and the tail is the last lines, never a mid-line cut.
  def test_a_running_command_posts_its_tail_through_the_context_at_the_cadence
    with_tool_env do |env, _root|
      posts = []
      clock = -> { monotonic }
      progress = Rho::Runner::Progress.new(post: ->(text) { posts << [monotonic, text]; true }, clock: clock,
        interval_ms: 100)
      context = Rho::Runner::ExecutionContext.new(progress: progress, clock: clock)
      pool = Rho::Runner::Pool.new(worker_threads: 1)
      ticket = pool.reserve
      result = pool.run(ticket, context) do
        Rho::Runner::ExecutionContext.with(context) do
          call_bash(env, "for i in 1 2 3 4 5 6; do echo tick $i; sleep 0.08; done")
        end
      end
      pool.stop

      refute result.is_error, result.content
      refute_empty posts, "a command that prints over half a second posts at least one tail before it answers"
      assert posts.all? { |_at, text| text.match?(/\Atick \d\n/) }, "a tail opens on a whole line: #{posts.inspect}"
      assert_operator posts.last.last.lines.length, :>, posts.first.last.lines.length,
        "later frames carry the longer tail"
      gaps = posts.each_cons(2).map { |(a, _), (b, _)| b - a }
      assert gaps.all? { |gap| gap >= 0.09 }, "one frame per interval: #{gaps.inspect}"
    end
  end

  # AN INTERRUPTED COMMAND MUST KILL ITS PROCESS GROUP, not orphan it. The
  # predecessor proved this twice — once by stopping the fiber its handler ran
  # on, once by cancelling the context from another thread. Only the second
  # applies here: a handler runs on a native worker and never on a fiber, so
  # the fiber variant tested a placement this runner does not have.
  def test_execution_context_cancellation_kills_and_reaps_the_process_group
    with_tool_env do |env, root|
      context = Rho::Runner::ExecutionContext.new
      pid_path = File.join(root, "pid")
      outcome = Thread::Queue.new
      worker = Thread.new do
        outcome << begin
          Rho::Runner::ExecutionContext.with(context) do
            Rho::Runner::Tools::Bash.new(env:).call(
              { "command" => "ps -o pgid= -p $$ | tr -d ' ' > pid; sleep 30" }
            )
          end
        rescue StandardError => error
          error
        end
      end

      deadline = monotonic + 5
      until File.exist?(pid_path) && !File.read(pid_path).empty?
        raise "bash never started" if monotonic > deadline

        sleep 0.02
      end
      pgid = File.read(pid_path).to_i

      context.cancel

      assert worker.join(1), "cooperative cancellation must promptly release the execution worker"
      assert_instance_of Rho::Runner::ExecutionContext::Cancelled, outcome.pop
      assert process_group_gone?(pgid), "expected process group #{pgid} to be killed on cancellation"
    ensure
      if pgid&.positive?
        begin
          Process.kill("KILL", -pgid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
      worker&.join(2)
    end
  end

  # THE DEADLINE KILLS THE GROUP TOO. Under the pool's clamp a
  # context's deadline fires the same signal a cancel does — `bash`'s
  # process group is dead within the grace, not at its own wall clock —
  # and the handler answers through its checkpoint with the DEADLINE
  # reason, which is what the runner turns into a timed-out result.
  def test_the_context_deadline_kills_and_reaps_the_process_group_with_the_deadline_reason
    with_tool_env do |env, root|
      context = Rho::Runner::ExecutionContext.new(deadline: monotonic + 0.5)
      pid_path = File.join(root, "pid")
      outcome = Thread::Queue.new
      worker = Thread.new do
        outcome << begin
          Rho::Runner::ExecutionContext.with(context) do
            Rho::Runner::Tools::Bash.new(env:).call(
              { "command" => "ps -o pgid= -p $$ | tr -d ' ' > pid; sleep 30" }
            )
          end
        rescue StandardError => error
          error
        end
      end

      deadline = monotonic + 5
      until File.exist?(pid_path) && !File.read(pid_path).empty?
        raise "bash never started" if monotonic > deadline

        sleep 0.02
      end
      pgid = File.read(pid_path).to_i

      assert worker.join(2), "the deadline must release the execution worker"
      raised = outcome.pop
      assert_instance_of Rho::Runner::ExecutionContext::Cancelled, raised
      assert_equal :deadline, raised.reason, "the reason travels with the exception, not only its message"
      assert process_group_gone?(pgid), "expected process group #{pgid} to be killed at the deadline"
    ensure
      if pgid&.positive?
        begin
          Process.kill("KILL", -pgid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
      worker&.join(2)
    end
  end

  private

  # THE PARAMETER BASH WAS THE ONLY TOOL WITHOUT. The other six take a
  # path; this one ran everything in the runner's root, so placing a
  # command meant `cd X && ...` in every call — and forgetting it ran the
  # command somewhere the caller never named, successfully, with output
  # that looked right.
  def test_workdir_places_the_command_without_a_cd
    with_tool_env do |env, root|
      Dir.mkdir(File.join(root, "project"))
      File.write(File.join(root, "project", "marker.txt"), "here")

      result = call_bash(env, "ls", { "workdir" => "project" })

      refute result.is_error, result.content
      assert_includes result.content, "marker.txt"
    end
  end

  def test_workdir_takes_an_absolute_path_too
    with_tool_env do |env, root|
      Dir.mkdir(File.join(root, "elsewhere"))
      File.write(File.join(root, "elsewhere", "found.txt"), "x")

      result = call_bash(env, "ls", { "workdir" => File.join(root, "elsewhere") })

      assert_includes result.content, "found.txt"
    end
  end

  def test_without_workdir_it_still_runs_in_the_runner_root
    with_tool_env do |env, root|
      File.write(File.join(root, "at-root.txt"), "x")

      assert_includes call_bash(env, "ls").content, "at-root.txt"
    end
  end

  # A directory that does not exist is a REFUSAL the model reads, not a
  # command run somewhere else.
  def test_a_missing_workdir_is_refused_rather_than_silently_relocated
    with_tool_env do |env, _root|
      result = call_bash(env, "ls", { "workdir" => "nope" })

      assert result.is_error
      assert_includes result.content, "Working directory does not exist"
      assert_includes result.content, "nope"
    end
  end

  # The suite runs under `bundle exec`, so this process carries Bundler's
  # trail; a child that inherited it would load rho's Gemfile.
  def test_the_child_does_not_inherit_bundlers_environment
    with_tool_env do |env, _root|
      result = call_bash(env, "env")

      refute_match(/^BUNDLE_GEMFILE=/, result.content, "the child inherited rho's Gemfile")
      refute_match(/^RUBYOPT=.*bundler/, result.content)
      assert_includes result.content, "PYTHONUNBUFFERED=1"
    end
  end

  def call_bash(env, command, extra = {})
    Rho::Runner::Tools::Bash.new(env:).call({ "command" => command }.merge(extra))
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Deadline-based like the startup wait in the cancellation test: SIGKILL
  # delivery + reap can lag well past a second when the suite runs under load.
  # EPERM is macOS's answer for a group of nothing but zombies — a KILLed
  # grandchild waiting on launchd's reap, not ours to `waitpid` — so it is
  # "not yet", polled on to ESRCH, never a verdict of its own; a group with
  # a LIVE member of ours answers neither error and runs out the deadline.
  def process_group_gone?(pgid)
    deadline = monotonic + 5
    while monotonic < deadline
      begin
        Process.kill(0, -pgid)
      rescue Errno::ESRCH
        return true
      rescue Errno::EPERM
        nil
      end
      sleep 0.05
    end
    false
  end
end
