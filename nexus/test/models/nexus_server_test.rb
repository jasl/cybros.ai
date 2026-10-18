require "test_helper"

# THE DATABASE IS THE AUTHORITY for which presence marks are live (r-modes
# M4 as amended): each socket-serving Nexus process keeps one row alive with
# a Nexus-internal heartbeat, and a mark is online only while the row it
# names is. Never a client heartbeat, never a gate.
class NexusServerTest < ActiveSupport::TestCase
  setup do
    @boot_id = Rails.application.config.x.nexus_server_boot_id
    @boot_pid = Rails.application.config.x.nexus_server_boot_pid
    @heartbeat = Rails.application.config.x.nexus_server_heartbeat
  end

  teardown do
    Rails.application.config.x.nexus_server_boot_id = @boot_id
    Rails.application.config.x.nexus_server_boot_pid = @boot_pid
    Rails.application.config.x.nexus_server_heartbeat = @heartbeat
  end

  test "the boot id is one per process, stable across calls and present with no row" do
    assert_equal 0, NexusServer.where(boot_id: NexusServer.boot_id).count
    assert_equal NexusServer.boot_id, NexusServer.boot_id
    assert_equal 36, NexusServer.boot_id.length
    assert_nil Rails.application.config.x.nexus_server_heartbeat
  end

  test "a fresh model class preserves the registered process and both old and new presence marks" do
    server = NexusServer.register
    executor = executors(:address)
    executor.mark_connected("before-reload")
    namespace = Module.new

    # Load the real definition into a fresh class without reloading every
    # model and invalidating the test suite's fixture references.
    stub_const(self.class, :ReloadedModels, namespace, exists: false) do
      load Rails.root.join("app/models/nexus_server.rb"), namespace
      reloaded = namespace.const_get(:NexusServer, false)

      assert_not_same NexusServer, reloaded
      assert_equal server.boot_id, reloaded.boot_id

      travel NexusServer::SERVER_LIVENESS_WINDOW + 1.second do
        assert_equal 1, reloaded.heartbeat
        assert_equal "online", Nexus::Presence.of(executor, live_server_ids: reloaded.live_ids)

        stub_const(Object, :NexusServer, reloaded) do
          executor.mark_connected("after-reload")
        end

        assert_equal server.boot_id, executor.presence_server_id
        assert_equal "online", Nexus::Presence.of(executor, live_server_ids: reloaded.live_ids)
        assert_equal 1, reloaded.deregister
        assert_empty reloaded.live_ids
      end
    end
  end

  test "register writes the process's row with host, pid and both clocks" do
    freeze_time do
      server = NexusServer.register

      assert_equal NexusServer.boot_id, server.boot_id
      assert_equal Socket.gethostname, server.host
      assert_equal Process.pid, server.pid
      assert_equal Time.current, server.started_at
      assert_equal Time.current, server.heartbeat_at
    end
  end

  test "heartbeat touches only heartbeat_at" do
    server = NexusServer.register
    started_at = server.started_at

    travel 15.seconds do
      NexusServer.heartbeat

      server.reload
      assert_equal Time.current, server.heartbeat_at
      assert_equal started_at, server.started_at
    end
  end

  test "live is a heartbeat within the window, and live_ids is the one read a page takes" do
    NexusServer.register
    stale = NexusServer.create!(boot_id: SecureRandom.uuid, host: "elsewhere", pid: 1,
      started_at: 2.minutes.ago, heartbeat_at: 2.minutes.ago)

    assert_equal [NexusServer.boot_id], NexusServer.live_ids
    assert_not_includes NexusServer.live.pluck(:boot_id), stale.boot_id

    travel NexusServer::SERVER_LIVENESS_WINDOW + 1.second do
      assert_empty NexusServer.live_ids
    end
  end

  test "deregister deletes only this boot's row" do
    NexusServer.register
    sibling = NexusServer.create!(boot_id: SecureRandom.uuid, host: "sibling", pid: 2,
      started_at: Time.current, heartbeat_at: Time.current)

    NexusServer.deregister

    assert_equal 0, NexusServer.where(boot_id: NexusServer.boot_id).count
    assert NexusServer.exists?(sibling.id)
  end

  test "reap_dead deletes rows dead for an hour and keeps a live one" do
    NexusServer.register
    dead = NexusServer.create!(boot_id: SecureRandom.uuid, host: "dead", pid: 3,
      started_at: 2.hours.ago, heartbeat_at: NexusServer::DEAD_AFTER.ago - 1.second)
    recent = NexusServer.create!(boot_id: SecureRandom.uuid, host: "recent", pid: 4,
      started_at: 5.minutes.ago, heartbeat_at: 5.minutes.ago)

    assert_equal 1, NexusServer.reap_dead

    assert_not NexusServer.exists?(dead.id)
    assert NexusServer.exists?(recent.id), "a row within the hour is offline, not yet reaped"
    assert_equal 1, NexusServer.where(boot_id: NexusServer.boot_id).count
  end

  test "the recurring schedule prunes dead server rows every minute" do
    assert_equal "NexusServers::ReapJob",
      recurring_schedule.dig("reap_dead_nexus_servers", "class")
    assert_equal "every minute", recurring_schedule.dig("reap_dead_nexus_servers", "schedule")
  end

  test "single server startup retains its socket identity and stops its heartbeat before deregistering" do
    Rails.application.config.x.nexus_server_boot_pid = Process.pid
    timer = Minitest::Mock.new
    timer.expect(:shutdown, nil) { assert NexusServer.exists?(boot_id: NexusServer.boot_id) }
    tick = nil
    start_timer = lambda do |execution_interval:, &block|
      assert_equal NexusServer::HEARTBEAT_INTERVAL.to_i, execution_interval
      tick = block
      timer
    end

    Concurrent::TimerTask.stub(:execute, start_timer) do
      NexusServer.start
    end

    assert_equal @boot_id, NexusServer.boot_id
    server = NexusServer.find_by!(boot_id: NexusServer.boot_id)
    travel 15.seconds do
      tick.call
      assert_in_delta Time.current, server.reload.heartbeat_at, 0.001
    end

    NexusServer.stop

    timer.verify
    assert_not NexusServer.exists?(server.id)
    assert_nil Rails.application.config.x.nexus_server_heartbeat
  end

  test "a preloaded worker receives its own identity and never heartbeats or removes a sibling" do
    sibling = NexusServer.register
    timer = Minitest::Mock.new
    timer.expect(:shutdown, nil)
    tick = nil
    start_timer = lambda do |execution_interval:, &block|
      tick = block
      timer
    end
    worker_pid = Process.pid + 1

    Concurrent::TimerTask.stub(:execute, start_timer) do
      Process.stub(:pid, worker_pid) { NexusServer.start }
    end

    assert_not_equal sibling.boot_id, NexusServer.boot_id
    worker = NexusServer.find_by!(boot_id: NexusServer.boot_id)
    assert_equal worker_pid, worker.pid
    sibling_heartbeat = sibling.heartbeat_at
    travel 15.seconds do
      tick.call
      assert_in_delta Time.current, worker.reload.heartbeat_at, 0.001
      assert_equal sibling_heartbeat, sibling.reload.heartbeat_at
    end

    NexusServer.stop

    timer.verify
    assert_not NexusServer.exists?(worker.id)
    assert NexusServer.exists?(sibling.id)
  end

  test "the reap job is the pruner" do
    NexusServer.create!(boot_id: SecureRandom.uuid, host: "dead", pid: 5,
      started_at: 2.hours.ago, heartbeat_at: 2.hours.ago)

    NexusServers::ReapJob.perform_now

    assert_equal 0, NexusServer.count
  end
end
