production = ENV.fetch("RAILS_ENV") { ENV.fetch("RACK_ENV", "development") } == "production"

# Keep production request threads low to reduce competition for Ruby's GVL.
# Puma owns explicit WEB_CONCURRENCY values, including 0 (single mode) and auto.
# Size the default inside the server/container so CPU quotas are respected.
threads ENV.fetch("RAILS_MAX_THREADS", production ? 1 : 3)
if production && ENV["WEB_CONCURRENCY"].to_s.strip.empty?
  require "concurrent/utility/processor_counter"
  workers Concurrent.available_processor_count.floor.clamp(1, 4)
end

# Presence belongs to each process serving sockets, never the preloading master.
single_mode = false
single do
  single_mode = true
  silence_fork_callback_warning
end

# Puma can evaluate mode blocks more than once, so install lifecycle hooks here.
after_booted { NexusServer.start if single_mode }
# Puma fires this callback from its TERM trap; database/timer locks need a thread.
after_stopped { Thread.new { NexusServer.stop }.join if single_mode }
before_restart { NexusServer.stop if single_mode }

before_worker_boot do
  require_relative "environment"
  NexusServer.start
rescue => error
  # Puma logs StandardError from worker hooks and continues; presence is required.
  abort error.full_message
end
before_worker_shutdown { NexusServer.stop }

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Opt-in: SOLID_QUEUE_IN_PUMA=true runs the Solid Queue supervisor inside
# Puma for single-process deployments; compose runs bin/jobs separately.
if %w[t true 1].include?(ENV["SOLID_QUEUE_IN_PUMA"].to_s.downcase)
  plugin :solid_queue
end

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
