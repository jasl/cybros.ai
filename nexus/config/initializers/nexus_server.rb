# The Nexus process's liveness row: registered at server start, heartbeated
# every NexusServer::HEARTBEAT_INTERVAL from one Concurrent::TimerTask on
# its own thread (the Rails executor wrap checks a connection out and in),
# deleted on a graceful stop (puma in single mode runs `at_exit` on
# TERM/INT; a SIGKILL leaves the row until the liveness window passes).
# Registered here, RUN by the server hook alone
# (`Rails.application.load_server`, config.ru): the initializer itself
# touches no database, and a rake task, a console or a test process never
# registers.
# Keep the identity outside reloadable model classes. Every process has an
# id, while only a socket-serving process registers its row below.
Rails.application.config.x.nexus_server_boot_id = SecureRandom.uuid

Rails.application.server do
  NexusServer.register
  Concurrent::TimerTask.execute(execution_interval: NexusServer::HEARTBEAT_INTERVAL.to_i) do
    Rails.application.executor.wrap { NexusServer.heartbeat }
  end
  at_exit { Rails.application.executor.wrap { NexusServer.deregister } }
end
