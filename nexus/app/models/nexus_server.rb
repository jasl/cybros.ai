# THE DATABASE IS THE AUTHORITY for which presence marks are live. Each
# socket-serving Nexus process registers one row at server start under its
# boot id and touches `heartbeat_at` every HEARTBEAT_INTERVAL from its own
# timer task — a NEXUS-INTERNAL liveness row, never a client heartbeat. A presence mark
# (`executors.presence_server_id`) is online iff the row it names has a
# heartbeat within SERVER_LIVENESS_WINDOW: a graceful stop deletes the row,
# so its marks read offline at once; a hard-killed process's marks read
# offline within the window with no sweep, no re-mark and no wrong clearing
# of a sibling's marks; its live clients reconnect and mark again under the
# new boot id. Display only — never a gate (test/lib/nexus/presence_test.rb
# pins that no service or job reads this table). Puma's serving-process hooks
# start and stop the timer; its preloading master never registers a row.
class NexusServer < ApplicationRecord
  HEARTBEAT_INTERVAL = 10.seconds
  # Three missed beats — the pong layer's own ratio.
  SERVER_LIVENESS_WINDOW = 30.seconds
  DEAD_AFTER = 1.hour

  scope :live, -> { where(heartbeat_at: SERVER_LIVENESS_WINDOW.ago..) }

  class << self
    # Application configuration survives model reloads, keeping socket marks
    # and heartbeats attached to the row registered at process start.
    def boot_id = Rails.application.config.x.nexus_server_boot_id

    def start
      configuration = Rails.application.config.x
      # Preloaded workers inherit the master's configuration, but never its
      # identity. Single mode keeps the id available to its first socket.
      if configuration.nexus_server_boot_pid != Process.pid
        configuration.nexus_server_boot_id = SecureRandom.uuid
        configuration.nexus_server_boot_pid = Process.pid
      end

      Rails.application.executor.wrap { register }
      configuration.nexus_server_heartbeat = Concurrent::TimerTask.execute(execution_interval: HEARTBEAT_INTERVAL.to_i) do
        Rails.application.executor.wrap { NexusServer.heartbeat }
      end
    end

    def stop
      configuration = Rails.application.config.x
      configuration.nexus_server_heartbeat&.shutdown
      Rails.application.executor.wrap { deregister }
      configuration.nexus_server_heartbeat = nil
    end

    def register
      now = Time.current
      create!(boot_id: boot_id, host: Socket.gethostname, pid: Process.pid,
        started_at: now, heartbeat_at: now)
    end

    # One UPDATE, no row lock, no model load.
    def heartbeat = where(boot_id: boot_id).update_all(heartbeat_at: Time.current)

    def deregister = where(boot_id: boot_id).delete_all

    # THE one read every page takes, once, and passes down (Nexus::Presence).
    def live_ids = live.pluck(:boot_id)

    # The prune: a row dead for an hour is history, not presence.
    def reap_dead = where(heartbeat_at: ...DEAD_AFTER.ago).delete_all
  end
end
