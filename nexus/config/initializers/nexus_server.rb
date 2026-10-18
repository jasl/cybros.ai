# Keep the process identity and timer outside reloadable model classes.
# Puma starts presence only in a serving process, after a preloaded worker
# has forked. Booting Rails for its master, rake, console or tests starts no
# timer and registers no row. A hard-killed server expires by its heartbeat.
Rails.application.config.x.nexus_server_boot_id = SecureRandom.uuid
Rails.application.config.x.nexus_server_boot_pid = Process.pid
Rails.application.config.x.nexus_server_heartbeat = nil
