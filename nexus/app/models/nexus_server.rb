# THE DATABASE IS THE AUTHORITY for which presence marks are live. Each
# socket-serving Nexus process registers one row at server start under its
# boot id and touches `heartbeat_at` every HEARTBEAT_INTERVAL from a single
# timer on the cable server's event loop — a NEXUS-INTERNAL liveness row,
# never a client heartbeat. A presence mark
# (`task_executors.presence_server_id`) is online iff the row it names has a
# heartbeat within SERVER_LIVENESS_WINDOW: a graceful stop deletes the row,
# so its marks read offline at once; a hard-killed process's marks read
# offline within the window with no sweep, no re-mark and no wrong clearing
# of a sibling's marks; its live clients reconnect and mark again under the
# new boot id. Display only — never a gate (test/lib/nexus/presence_test.rb
# pins that no service or job reads this table). Puma runs in single mode
# (`config/puma.rb` declares no `workers`); a cluster would need the boot id
# re-minted per worker in `on_worker_boot` and the hook re-run there —
# recorded, not built.
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
