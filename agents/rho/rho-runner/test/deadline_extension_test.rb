require "support/runner_loop_fixtures"

class DeadlineExtensionTest < Minitest::Test
  include RunnerLoopFixtures

  def test_renewals_follow_each_granted_window_instead_of_the_original_long_park
    now = 0.0
    answers = [[46_785.0, "second", 3_600.0], [48_585.0, "third", 3_600.0], nil]
    extension = Rho::Runner::DeadlineExtension.new(
      park_seconds: 86_400.0, deadline_at: "first", clock: -> { now }
    ) { answers.shift }

    now = extension.due_at
    assert_equal 43_200.0, now
    assert_equal 46_785.0, extension.call
    assert_equal 45_000.0, extension.due_at
    assert_operator extension.due_at, :<, 46_785.0

    now = extension.due_at
    assert_equal 48_585.0, extension.call
    assert_equal 46_800.0, extension.due_at
    assert_operator extension.due_at, :<, 48_585.0

    now = extension.due_at
    assert_nil extension.call
    assert_predicate extension, :stopped?
    assert_nil extension.wait
    assert_equal "third", extension.deadline_at
  end

  def test_the_tools_announced_park_is_capped_and_the_granted_window_reaches_the_timer
    task = row("t1", timeout_ms: 86_400_000)
    lane = Lane.new(rows: [task])
    tools = toolset(timeout_ms: 86_400_000)
    pool = Rho::Runner::Pool.new(worker_threads: 1)
    run = Rho::Runner::TaskRun.new(executor: lane, pool: pool,
      toolsets: fixed(tools), log: Silent.new, clock: -> { 10.0 }, sleeper: ->(_) { nil })
    claimed = Claimed.new(task: task, claim_token: "tok", deadline_at: nil)

    deadline, deadline_at, park = run.send(:request_extension, claimed, tools.fetch("echo"))

    assert_equal 3_600_000, lane.extends.fetch(0).fetch(:timeout_ms)
    assert_in_delta 3_600.0, park, 0.1
    assert_in_delta 3_595.0, deadline, 0.1
    assert_in_delta Time.now.to_f + 3_600, Time.parse(deadline_at).to_f, 0.1
  ensure
    pool&.stop
  end
end
