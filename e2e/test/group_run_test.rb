require "test_helper"
require "rbconfig"
require "stringio"
require "tmpdir"
require "support/group_run"

# The parent's mechanics with no Nexus and no browser: three fake groups
# whose command is a ruby one-liner exiting by group key.
class GroupRunTest < Minitest::Test
  def test_a_child_gets_exactly_the_three_keys_and_no_pinned_port
    run = E2E::GroupRun.new(groups: [1], deadline: 900, log_dir: Dir.tmpdir)

    assert_equal(
      { "E2E_ASSETS_PREPARED" => "1", "E2E_DEADLINE_SECONDS" => "900", "E2E_NEXUS_PORT" => nil },
      run.child_env(1)
    )
  end

  def test_one_failing_group_fails_the_run_and_is_named_with_its_log_tailed
    Dir.mktmpdir do |logs|
      run = E2E::GroupRun.new(groups: [1, 2, 3], deadline: 30, log_dir: logs)
      out = StringIO.new

      ok = run.run(command: ->(k) { [RbConfig.ruby, "-e", "puts 'group ' + ARGV[0]; exit(ARGV[0] == '2' ? 1 : 0)", k.to_s] },
        out: out)

      refute ok
      assert_equal %w[1.log 2.log 3.log], Dir.children(logs).sort
      assert_match(/^group 2  FAIL +\d+ s  #{Regexp.escape(File.join(logs, "2.log"))}$/, out.string)
      assert_match(/^group 1  pass +\d+ s  /, out.string)
      assert_match(/^group 3  pass +\d+ s  /, out.string)
      assert_match(/---- group 2 failed; last 60 lines of .*2\.log ----\ngroup 2\n/, out.string)
      assert_equal "group 2\n", File.read(File.join(logs, "2.log"))
    end
  end

  def test_all_groups_passing_is_true
    Dir.mktmpdir do |logs|
      run = E2E::GroupRun.new(groups: [1, 2, 3], deadline: 30, log_dir: logs)
      out = StringIO.new

      assert run.run(command: ->(k) { [RbConfig.ruby, "-e", "exit 0", k.to_s] }, out: out)
      assert_equal 3, out.string.scan(/^group \d  pass/).size
    end
  end

  # THE PARENT IS A RAKE PROCESS, NOT A TEST PROCESS: it has `Minitest` from
  # minitest/test_task and nothing else of the runner. The registry's sweep
  # hook must not assume the runner is there — the first parallel run died
  # on exactly that, spawning one group and leaving it orphaned.
  def test_the_parent_runs_where_only_minitests_rake_task_is_loaded
    Dir.mktmpdir do |logs|
      support = File.expand_path("../support", __dir__)
      script = <<~RUBY
        require "minitest/test_task"
        require File.join(ARGV.fetch(0), "group_run")
        run = E2E::GroupRun.new(groups: [1, 2], deadline: 30, log_dir: ARGV.fetch(1))
        exit(run.run(command: ->(k) { [RbConfig.ruby, "-e", "exit 0", k.to_s] }, out: $stdout) ? 0 : 1)
      RUBY

      status = E2E::ProcessRunner.run(RbConfig.ruby, "-e", script, support, logs, timeout: 20, out: File::NULL)

      assert_predicate status, :success?, "the parent could not run its groups with only the rake task loaded"
      assert_equal %w[1.log 2.log], Dir.children(logs).sort
    end
  end

  # THE SLOT COUNT IS THE MACHINE'S CEILING, not the manifest's: with one
  # slot the three groups run one after another and never overlap.
  def test_slots_bound_how_many_worlds_run_at_once
    Dir.mktmpdir do |logs|
      run = E2E::GroupRun.new(groups: [1, 2, 3], deadline: 30, log_dir: logs, slots: 1)
      clock = "Process.clock_gettime(Process::CLOCK_MONOTONIC)"
      command = ->(k) { [RbConfig.ruby, "-e", "puts #{clock}; sleep 0.3; puts #{clock}", k.to_s] }

      assert run.run(command: command, out: StringIO.new)

      spans = [1, 2, 3].map { |k| File.readlines(File.join(logs, "#{k}.log")).map(&:to_f) }
      spans.combination(2).each do |(a_start, a_end), (b_start, b_end)|
        assert a_end <= b_start || b_end <= a_start, "two worlds overlapped under one slot: #{spans.inspect}"
      end
    end
  end

  # The printed seconds are a group's own: a world that queued for a slot
  # reports its run, not its wait, so WEIGHTS can be copied from the line.
  def test_a_queued_group_reports_its_own_seconds_not_its_wait
    Dir.mktmpdir do |logs|
      run = E2E::GroupRun.new(groups: [1, 2, 3], deadline: 30, log_dir: logs, slots: 1)
      out = StringIO.new

      assert run.run(command: ->(k) { [RbConfig.ruby, "-e", "sleep 1.1", k.to_s] }, out: out)

      seconds = out.string.scan(/^group \d  pass +(\d+) s/).flatten.map(&:to_i)
      assert_equal 3, seconds.size
      seconds.each { |own| assert_operator own, :<, 3, "a queued group reported its wait as its own time: #{out.string}" }
    end
  end

  def test_a_group_past_the_bound_is_terminated_and_fails
    Dir.mktmpdir do |logs|
      run = E2E::GroupRun.new(groups: [1], deadline: 0, log_dir: logs, reap_grace: 1)
      out = StringIO.new

      refute run.run(command: ->(k) { [RbConfig.ruby, "-e", "sleep 30", k.to_s] }, out: out)

      assert_match(/^group 1  FAIL +\d+ s  .*\(exceeded 1 s\)$/, out.string)
    end
  end
end
