require "test_helper"
require_relative "../../test_helpers/awaits_test_helper"

class AgentRuns::MaintenanceClockTest < ActiveJob::TestCase
  include AwaitsTestHelper

  test "maintenance preserves an unanswered park past its wall deadline" do
    travel_to Time.current.change(usec: 0)
    agent_run = seed(await("gate", "timeout_ms" => 1.hour.in_milliseconds))
    start!(agent_run)
    gate = node(agent_run, "gate")

    travel 30.minutes
    @account.update!(maintenance_started_at: Time.current)
    travel 2.hours

    sweep = DatabaseClock.stub(:now, Time.current) { AgentRuns::Parks::TimeoutSweep.call }
    assert_equal 0, sweep[:expired]
    assert_equal "dispatched", gate.reload.status
    assert_predicate resolve!(gate, content: "approved during maintenance"), :applied?
    assert_equal "completed", gate.reload.status
    assert_equal "approved during maintenance", gate.content_bodies.find_by!(role: "output").effective_text
  end

  test "resuming a prior user pause during maintenance repays only time before maintenance" do
    travel_to Time.current.change(usec: 0)
    agent_run = seed(await("gate", "timeout_ms" => 1.hour.in_milliseconds))
    start!(agent_run)
    gate = node(agent_run, "gate")
    armed_at = gate.await_started_at

    travel 10.minutes
    pause!(agent_run)
    travel 20.minutes
    maintenance_at = Time.current
    @account.update!(maintenance_started_at: maintenance_at)
    travel 2.hours

    resume!(agent_run)

    assert_equal armed_at + 20.minutes, gate.reload.await_started_at
    assert_nil agent_run.reload.paused_at
    assert_equal maintenance_at, agent_run.effective_now
    DatabaseClock.stub(:now, Time.current) { Deployments::Maintenance.resume }
    assert_equal armed_at + 140.minutes, gate.reload.await_started_at
    assert_predicate resolve!(gate), :applied?
    assert_equal "completed", gate.reload.status
  end

  test "a pause and resume wholly inside maintenance do not repay the same frozen interval" do
    travel_to Time.current.change(usec: 0)
    agent_run = seed(await("gate", "timeout_ms" => 1.hour.in_milliseconds))
    start!(agent_run)
    gate = node(agent_run, "gate")
    armed_at = gate.await_started_at

    travel 10.minutes
    maintenance_at = Time.current
    @account.update!(maintenance_started_at: maintenance_at)
    travel 20.minutes
    pause!(agent_run)
    assert_equal maintenance_at, agent_run.reload.paused_at
    travel 2.hours
    resume!(agent_run)

    assert_equal armed_at, gate.reload.await_started_at
    assert_equal maintenance_at, agent_run.reload.effective_now
    assert_predicate resolve!(gate), :applied?
    assert_equal "completed", gate.reload.status
  end

  test "a user pause spanning maintenance remains paused and repays the full interval once" do
    travel_to Time.current.change(usec: 0)
    agent_run = seed(await("gate", "timeout_ms" => 1.hour.in_milliseconds))
    start!(agent_run)
    gate = node(agent_run, "gate")
    armed_at = gate.await_started_at

    travel 10.minutes
    pause!(agent_run)
    paused_at = agent_run.reload.paused_at
    travel 20.minutes
    @account.update!(maintenance_started_at: Time.current)
    travel 2.hours
    assert_equal paused_at, agent_run.effective_now
    DatabaseClock.stub(:now, Time.current) { Deployments::Maintenance.resume }
    assert_predicate agent_run.reload, :paused?
    assert_equal paused_at, agent_run.effective_now
    travel 10.minutes
    resume!(agent_run)

    assert_equal armed_at + 150.minutes, gate.reload.await_started_at
    assert_nil agent_run.reload.paused_at
    assert_predicate resolve!(gate), :applied?
    assert_equal "completed", gate.reload.status
  end

  test "a graceful stop during maintenance keeps its full drain window after resume" do
    travel_to Time.current.change(usec: 0)
    agent_run = seed(await("gate", "timeout_ms" => 24.hours.in_milliseconds))
    start!(agent_run)
    gate = node(agent_run, "gate")
    maintenance_at = Time.current
    @account.update!(maintenance_started_at: maintenance_at)
    travel 2.hours
    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: false
    )), :accepted?
    assert_equal maintenance_at, agent_run.reload.canceling_since
    travel 25.hours

    assert_equal 0, AgentRuns::DrainSweep.call[:escalated]
    assert_equal "canceling", agent_run.reload.status
    assert_equal "dispatched", gate.reload.status
    assert_not_predicate gate, :deadline_passed?

    DatabaseClock.stub(:now, Time.current) { Deployments::Maintenance.resume }
    assert_equal Time.current, agent_run.reload.canceling_since
    assert_equal Time.current + 24.hours, gate.reload.deadline_at
    travel 23.hours + 59.minutes
    assert_equal 0, AgentRuns::DrainSweep.call[:escalated]
    travel 1.minute
    assert_equal 1, AgentRuns::DrainSweep.call[:escalated]
    assert_equal "canceled", agent_run.reload.status
    assert_equal "canceled", gate.reload.status
  end

  private

    def pause!(agent_run)
      assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
        agent_run: agent_run, acting_user: @human
      )), :accepted?
    end

    def resume!(agent_run)
      assert_predicate AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
        agent_run: agent_run, acting_user: @human
      )), :accepted?
    end
end
