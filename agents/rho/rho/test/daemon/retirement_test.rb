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
    daemon = inference_request_ready(boot(realtime_factory: ->(*) { realtime }))
    about = daemon.lineage.credentials
    run = fake_run("os-1")
    run.define_singleton_method(:realtime) { realtime }
    run.define_singleton_method(:stop) do
      events << [:stop, Thread.current, !Async::Task.current?.nil?]
    end
    daemon.lineage.install_follower(about, run)
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
    assert_empty daemon.lineage.followers
    assert_nil daemon.lineage.realtime
    assert_nil daemon.lineage.executor_realtime
  end

  def test_adopting_a_replacement_lineage_retires_the_old_runs_on_their_reactor
    events = Queue.new
    realtime = Object.new
    realtime.define_singleton_method(:close) do
      events << [:close, Thread.current, !Async::Task.current?.nil?]
    end
    daemon = inference_request_ready(boot(realtime_factory: ->(*) { realtime }))
    old_credentials = daemon.lineage.credentials
    run = fake_run("os-1")
    run.define_singleton_method(:realtime) { realtime }
    run.define_singleton_method(:stop) do
      events << [:stop, Thread.current, !Async::Task.current?.nil?]
    end
    daemon.lineage.install_follower(old_credentials, run)
    daemon.lineage.realtime_for(old_credentials)
    replacement = Rho::Credentials.new
    identity = Data.define(:user_public_id, :executor_public_id, :runner_executor_public_id).new(
      user_public_id: "user-new", executor_public_id: "executor-new", runner_executor_public_id: nil
    )
    caller_thread = Thread.current

    daemon.send(:adopt_connection, identity: identity, credentials: replacement)
    stopped, closed = 2.times.map { events.pop(timeout: 2) }

    assert_same replacement, daemon.lineage.credentials
    assert_empty daemon.lineage.followers
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
    daemon = inference_request_ready(boot(realtime_factory: ->(*) { realtime }))
    about = daemon.lineage.credentials
    run = fake_run("os-1")
    run.define_singleton_method(:realtime) { realtime }
    run.define_singleton_method(:stop) do
      events << [:stop, Thread.current, !Async::Task.current?.nil?]
    end
    daemon.lineage.install_follower(about, run)
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

  def test_shutdown_finishes_cleanup_released_by_a_pending_extension_callback
    deleted = Thread::Queue.new
    peer = Rho::ControlServer.new(bind: "127.0.0.1", port: 0, routes: {
      ["DELETE", "/agent_api/v1/workspaces/workspace/conversations/side"] => ->(_request) {
        deleted << true
        Protocol::HTTP::Response[204, {}, nil]
      },
    }).run
    $rho_cleanup_started, $rho_cleanup_finished = Thread::Queue.new, Thread::Queue.new
    path = File.join(@root, "leased_cleanup.rb")
    File.write(path, <<~RUBY)
      module LeasedCleanupExtension
        NAME = "rho.leased_cleanup"

        def self.register(api)
          side = CybrosAgent::Client.new(base_url: "http://127.0.0.1:#{peer.port}", credential: "test", request_timeout: 1)
            .workspace("workspace").conversation("side")
          api.on(:shutdown) do
            side.delete
            $rho_cleanup_finished << Thread.current
          end
          api.register_route("POST", "/fixture/hold", auth: :none) do |_request, ctx|
            lease = api.resources.acquire
            ctx.spawn do
              begin
                $rho_cleanup_started << Thread.current
                sleep
              ensure
                lease.release
              end
            end
            [202, {}]
          end
        end
      end
    RUBY
    plugin = RhoTest.described_extension(path, id: "rho.leased_cleanup")
    daemon = boot(config: Rho::Config.from_hash({ "plugins" => { "rho.leased_cleanup" => plugin } }))
    assert_equal "202", request(daemon, :post, "/fixture/hold").code
    owner = $rho_cleanup_started.pop(timeout: 5)
    refute_nil owner

    daemon.stop

    assert_same owner, $rho_cleanup_finished.pop(timeout: 1),
      "the last callback releases and finishes its cleanup on the same reactor before it closes"
    assert deleted.pop(timeout: 1)
  ensure
    daemon&.stop
    peer&.stop
    $rho_cleanup_started = $rho_cleanup_finished = nil
  end

  def test_a_retired_lineage_cannot_reopen_its_shared_client
    daemon = inference_request_ready(boot)
    about = daemon.lineage.credentials
    client = daemon.lineage.realtime_for(about)
    endpoint = client.send(:instance_variable_get, :@endpoint)

    assert_equal "Bearer member-token", endpoint.headers.fetch("Authorization")
    daemon.lineage.retire_runs

    assert_raises(CybrosAgent::Error) { endpoint.headers }
  end
end
