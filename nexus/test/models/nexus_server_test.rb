require "test_helper"

# THE DATABASE IS THE AUTHORITY for which presence marks are live (r-modes
# M4 as amended): each socket-serving Nexus process keeps one row alive with
# a Nexus-internal heartbeat, and a mark is online only while the row it
# names is. Never a client heartbeat, never a gate.
class NexusServerTest < ActiveSupport::TestCase
  test "the boot id is one per process, stable across calls and present with no row" do
    assert_equal 0, NexusServer.where(boot_id: NexusServer.boot_id).count
    assert_equal NexusServer.boot_id, NexusServer.boot_id
    assert_equal 36, NexusServer.boot_id.length
  end

  test "a fresh model class preserves the registered process and both old and new presence marks" do
    server = NexusServer.register
    executor = task_executors(:address)
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

  # The hook runs only under `load_server` (config.ru), which no test
  # process does — so its three calls are pinned by name against what
  # exists, the way a boot would find them.
  test "the server hook registers, beats on its own timer task and deregisters at exit" do
    source = Rails.root.join("config/initializers/nexus_server.rb").read

    assert_includes source, "Rails.application.server do"
    assert_includes source, "NexusServer.register"
    assert_includes source, "Concurrent::TimerTask.execute(execution_interval: NexusServer::HEARTBEAT_INTERVAL.to_i)"
    assert_includes source, "NexusServer.heartbeat"
    assert_includes source, "at_exit { Rails.application.executor.wrap { NexusServer.deregister } }"
  end

  test "the reap job is the pruner" do
    NexusServer.create!(boot_id: SecureRandom.uuid, host: "dead", pid: 5,
      started_at: 2.hours.ago, heartbeat_at: 2.hours.ago)

    NexusServers::ReapJob.perform_now

    assert_equal 0, NexusServer.count
  end
end
