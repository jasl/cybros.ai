require_relative "process_registry"
require_relative "process_runner"

module E2E
  # THE EXECUTION HOSTS, as the two separate processes a deployment runs.
  #
  # The harness ran only the web process, so no journey had ever put work
  # through the reactor that carries every text lane: `ModelRunner::Host#run` —
  # its LISTEN loop, its claim loop, its signal traps — had zero callers.
  #
  # BOTH ARE SPAWNED, AND EITHER CAN RUN ALONE. That is not tidiness, it is the only way a journey
  # can pin WHICH host executes a turn: `Wake` wakes both for a text lane and gives neither a
  # tiebreaker, so a journey that lets them race is asserting on whichever won. Both narrate the
  # same deltas now (one sink constructor, both hosts) — what pinning still buys is a named host for
  # the assertion, and the ability to stop the queue host, which is the only one that converges a
  # turn. Each is self-sufficient, because the runner drains admission itself
  # (`ModelRunner::Host#admission_loop`) exactly as the queue worker does.
  #
  # An earlier draft got the queue side from `SOLID_QUEUE_IN_PUMA`, which works
  # but welds the queue host to the web process and so makes pinning impossible
  # without a reboot.
  class NexusHosts
    # READINESS IS A FACT ABOUT THE HOST, never "the process still exists" —
    # which is what the predecessor polled and what its own comment called
    # sleep-and-hope. The two hosts say it differently: the runner logs a line
    # when its listener is up, and Solid Queue logs to the Rails log rather
    # than stdout but REGISTERS ITSELF in the database, which is the better
    # fact anyway.
    RUNNER_READY = "event=model_runner_started".freeze
    SUPERVISOR_REGISTERED = <<~RUBY.freeze
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
      until SolidQueue::Process.where(kind: "Worker").exists?
        abort("no Solid Queue worker registered") if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.2
      end
    RUBY
    READY_TIMEOUT = 60
    POLL = 0.1
    # THE PROCESS'S OWN RAILS LOG (nexus config/environments/development.rb):
    # the world's env names the web's file; each host gets a file of its own
    # beside its stdout log, so the dump shows what the jobs process did.
    RAILS_LOG_ENV = "RAILS_LOG_FILE".freeze

    Host = Struct.new(:name, :command, :ready, :log_path, :rails_log_path, :pid)

    def initialize(nexus_root:, env:, log_dir:)
      @nexus_root = nexus_root
      @env = env
      @hosts = {
        runner: Host.new("model runner", "bin/model_runner", :log_marker,
                         File.join(log_dir, "model_runner.log"), File.join(log_dir, "model_runner.rails.log")),
        jobs: Host.new("queue worker", "bin/jobs", :registered,
                       File.join(log_dir, "jobs.log"), File.join(log_dir, "jobs.rails.log")),
      }
    end

    # The deployment shape: both hosts, whoever claims first wins.
    def start(*names)
      names = @hosts.keys if names.empty?
      names.each { |name| start_host(@hosts.fetch(name)) }
      self
    end

    # ONLY these hosts run when this returns, so a journey states the
    # composition it needs rather than inheriting whatever the last one left.
    def pin(name)
      (@hosts.keys - [name]).each { |other| stop_host(@hosts.fetch(other)) }
      start_host(@hosts.fetch(name))
      self
    end

    def stop
      @hosts.each_value { |host| stop_host(host) }
      self
    end

    def log_path(name) = @hosts.fetch(name).log_path
    def rails_log_path(name) = @hosts.fetch(name).rails_log_path

    private

      def start_host(host)
        return host.pid if host.pid

        log_offset = File.size?(host.log_path) || 0
        host.pid = ProcessRegistry.spawn(
          host_env(host), File.join(@nexus_root, host.command),
          chdir: @nexus_root,
          out: [host.log_path, "a"], err: [host.log_path, "a"], pgroup: true
        )
        await_ready(host, log_offset: log_offset)
        host.pid
      rescue StandardError
        stop_host(host)
        raise
      end

      # The world's env with this host's own Rails log in place of the web's.
      def host_env(host) = @env.merge(RAILS_LOG_ENV => host.rails_log_path)

      def stop_host(host)
        return if host.pid.nil?

        ProcessRegistry.terminate(host.pid)
        host.pid = nil
      end

      def await_ready(host, log_offset:)
        case host.ready
        when :log_marker then await_log_marker(host, log_offset: log_offset)
        when :registered then await_registration(host)
        else raise ArgumentError, "unknown readiness kind #{host.ready.inspect}"
        end
      end

      def await_log_marker(host, log_offset:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT
        loop do
          if (result = Process.wait2(host.pid, Process::WNOHANG))
            raise "the #{host.name} exited before announcing itself (#{result.last.inspect}):\n#{tail(host)}"
          end

          # Logs retain every restart for failure dumps; only this process's bytes prove readiness.
          return if File.read(host.log_path, nil, log_offset).include?(RUNNER_READY)
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            raise "the #{host.name} never announced itself:\n#{tail(host)}"
          end

          sleep POLL
        end
      end

      # One boot that waits, rather than a boot per poll: `bin/rails runner`
      # costs seconds to start, so the waiting belongs inside the child. Its
      # boot lines land in the host's Rails log, not the web's.
      def await_registration(host)
        status = ProcessRunner.run(
          File.join(@nexus_root, "bin", "rails"), "runner", SUPERVISOR_REGISTERED,
          env: host_env(host), chdir: @nexus_root, out: File::NULL, err: File::NULL,
          timeout: READY_TIMEOUT
        )
        return if status.success?

        raise "the #{host.name} never registered:\n#{tail(host)}"
      end

      def tail(host)
        return "(no log at #{host.log_path})" unless File.exist?(host.log_path)

        File.readlines(host.log_path).last(20).join
      end
  end
end
