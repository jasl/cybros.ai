require "test_helper"

class DaemonRetirementTest < Minitest::Test
  include RhoTest::DaemonHarness

  # The other two edges END them, and the difference is the whole point of
  # having three: a lineage that died takes its followers with it, a rotation
  # does not.
  def test_losing_authority_stops_every_follower_and_forgets_them
    events = Queue.new
    realtime = Object.new
    realtime.define_singleton_method(:close) do
      events << [:close, Thread.current, !Async::Task.current?.nil?]
    end
    daemon = one_shot_ready(boot(realtime_factory: ->(*) { realtime }))
    about = daemon.lineage.credentials
    run = fake_run("os-1")
    run.define_singleton_method(:realtime) { realtime }
    run.define_singleton_method(:stop) do
      events << [:stop, Thread.current, !Async::Task.current?.nil?]
    end
    daemon.lineage.install_run(about, run)
    assert_same realtime, daemon.lineage.realtime_for(about)
    caller_thread = Thread.current

    daemon.send(:lose_authority)
    stopped, closed = 2.times.map { events.pop(timeout: 2) }

    assert_equal %i[stop close], [stopped&.first, closed&.first]
    [stopped, closed].each do |event|
      refute_nil event, "authority cleanup must reach the owning reactor"
      refute_same caller_thread, event.fetch(1)
      assert event.fetch(2), "Async resources are only mutated on their owning reactor"
    end
    assert_empty daemon.lineage.runs
    assert_nil daemon.lineage.realtime
    assert_nil daemon.lineage.executor_realtime
  end

  def test_adopting_a_replacement_lineage_retires_the_old_runs_on_their_reactor
    events = Queue.new
    realtime = Object.new
    realtime.define_singleton_method(:close) do
      events << [:close, Thread.current, !Async::Task.current?.nil?]
    end
    daemon = one_shot_ready(boot(realtime_factory: ->(*) { realtime }))
    old_credentials = daemon.lineage.credentials
    run = fake_run("os-1")
    run.define_singleton_method(:realtime) { realtime }
    run.define_singleton_method(:stop) do
      events << [:stop, Thread.current, !Async::Task.current?.nil?]
    end
    daemon.lineage.install_run(old_credentials, run)
    daemon.lineage.realtime_for(old_credentials)
    replacement = Rho::Credentials.new
    identity = Data.define(:user_public_id, :executor_public_id, :runner_executor_public_id).new(
      user_public_id: "user-new", executor_public_id: "executor-new", runner_executor_public_id: nil
    )
    caller_thread = Thread.current

    daemon.send(:adopt_connection, identity: identity, credentials: replacement)
    stopped, closed = 2.times.map { events.pop(timeout: 2) }

    assert_same replacement, daemon.lineage.credentials
    assert_empty daemon.lineage.runs
    assert_nil daemon.lineage.realtime
    assert_nil daemon.lineage.executor_realtime
    assert_equal %i[stop close], [stopped&.first, closed&.first]
    [stopped, closed].each do |event|
      refute_nil event, "replacement cleanup must reach the owning reactor"
      refute_same caller_thread, event.fetch(1)
      assert event.fetch(2), "old-lineage Async resources stay on their owning reactor"
    end
  end

  def test_shutdown_waits_for_owner_reactor_cleanup_before_interrupting_it
    events = Queue.new
    realtime = Object.new
    realtime.define_singleton_method(:close) do
      events << [:close, Thread.current, !Async::Task.current?.nil?]
    end
    daemon = one_shot_ready(boot(realtime_factory: ->(*) { realtime }))
    about = daemon.lineage.credentials
    run = fake_run("os-1")
    run.define_singleton_method(:realtime) { realtime }
    run.define_singleton_method(:stop) do
      events << [:stop, Thread.current, !Async::Task.current?.nil?]
    end
    daemon.lineage.install_run(about, run)
    daemon.lineage.realtime_for(about)
    caller_thread = Thread.current

    daemon.stop
    stopped, closed = 2.times.map { events.pop(timeout: 0) }

    assert_equal %i[stop close], [stopped&.first, closed&.first],
      "stop returns only after the owner reactor has performed synchronous cleanup"
    [stopped, closed].each do |event|
      refute_same caller_thread, event.fetch(1)
      assert event.fetch(2)
    end
    assert_nil daemon.lineage.executor_realtime
  end

  def test_a_retired_lineage_cannot_reopen_its_shared_client
    daemon = one_shot_ready(boot)
    about = daemon.lineage.credentials
    client = daemon.lineage.realtime_for(about)
    endpoint = client.send(:instance_variable_get, :@endpoint)

    assert_equal "Bearer member-token", endpoint.headers.fetch("Authorization")
    daemon.lineage.retire_runs

    assert_raises(CybrosAgent::Error) { endpoint.headers }
  end
end
