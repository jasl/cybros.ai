module Rho
  module Extensions
    module Processes
      # The product's definition of a background task, as verbs: how a person finds, reads and
      # closes a process a run started.
      module Commands
        # How long `rho kill` follows a stop: the registry's own TERM grace
        # plus the KILL, with room for a slow exit.
        KILL_WAIT = 10
        KILL_POLL = 0.2
        LOG_TAIL = 100

        class << self
          # The rows wherever they live: this machine's, then
          # each followed host's runner's — a remote row ends in its runner —
          # and a runner that could not answer says so on one line.
          def processes(cli, _args, options)
            path = options[:runner] ? "/processes?#{URI.encode_www_form("runner" => options[:runner])}" : "/processes"
            document = cli.core.parse(cli.core.get(cli.core.require_daemon, path, budget: relay_budget))
            raise ConnectionError, cli.core.failure_message(document) if document.key?("error")

            rows = Array(document["processes"])
            orphans = Array(document["orphans"])
            unreachable = Array(document["unreachable"])
            cli.out.puts "(no processes)" if rows.empty? && orphans.empty? && unreachable.empty?
            rows.each { |row| cli.out.puts process_line(row) }
            orphans.each do |orphan|
              cli.out.puts "  reaped at start, left by a previous daemon: #{orphan["id"]} " \
                           "pid #{orphan["pid"]} #{orphan["command"]}"
            end
            unreachable.each { |entry| cli.out.puts "runner #{entry["runner"]} could not answer: #{entry["error"]}" }
            rows
          end

          # TERM now and the daemon's own thread escalates; this polls the listing so the line it
          # prints is the final state. A group that died leaves the listing: the final state is
          # then the exit the daemon remembers behind the log door.
          def kill(cli, (id), options)
            deadline = options.fetch(:deadline, KILL_WAIT)
            clock = options.fetch(:clock) { -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) } }
            daemon = cli.core.require_daemon
            answer = cli.core.parse(cli.core.post(daemon, "/processes/stop", { id: id }, budget: Rho::Core::Budget::LOCAL))
            raise ConnectionError, cli.core.failure_message(answer) if answer.key?("error")

            row = answer.fetch("process")
            started = clock.call
            while row["status"] != "exited" && clock.call - started < deadline
              sleep KILL_POLL
              listing = Array(cli.core.parse(cli.core.get(daemon, "/processes"))["processes"])
              row = listing.find { |candidate| candidate["id"] == id } || remembered_exit(cli, daemon, id, row)
            end
            cli.out.puts process_line(row)
            row
          end

          def logs(cli, (id), options)
            tail = options.fetch(:tail, LOG_TAIL)
            query = { "id" => id, "lines" => Integer(tail) }
            query["runner"] = options[:runner] if options[:runner]
            document = cli.core.parse(cli.core.get(cli.core.require_daemon, "/processes/log?#{URI.encode_www_form(query)}",
              budget: relay_budget))
            raise ConnectionError, cli.core.failure_message(document) if document.key?("error")

            cli.out.puts process_line(document.fetch("process"))
            cli.out.puts "log: #{document["path"]}"
            Array(document["lines"]).each { |line| cli.out.puts line }
            document
          end

          private

            # The exit memory is bounded: a corpse it no longer holds ends
            # on the last row seen, as exited.
            def remembered_exit(cli, daemon, id, last)
              document = cli.core.parse(cli.core.get(daemon, "/processes/log?id=#{URI.encode_www_form_component(id)}&lines=1"))
              document.key?("error") ? last.merge("status" => "exited") : document.fetch("process")
            end

            # A read that may cross to a runner elsewhere waits the call_tool's
            # own clock and its patience, then the local round trip.
            def relay_budget
              Rho::Core::Budget.new(
                open: Rho::Core::LOCAL_OPEN_TIMEOUT,
                read: Rho::Core::Budget::KERNEL_ROUND_TRIP.read +
                  (Remote::TIMEOUT_MS / 1000.0).ceil + Remote::PATIENCE_SLACK_SECONDS.ceil
              )
            end

            def process_line(row)
              status = row["status"].to_s
              if status == "exited"
                how = row["signal"] ? "signal #{row["signal"]}" : "status #{row["exit_status"] || "-"}"
                status = "exited (#{how})"
              end
              name = row["name"] || row["command"].to_s.byteslice(0, 60).scrub("")
              line = "#{row["id"]}  #{status}  pid #{row["pid"]}  owner #{row["owner"] || "-"}"
              line << "  run #{row["run_public_id"]}" if row["run_public_id"] && row["run_public_id"] != row["owner"]
              line << "  #{name}  (#{row["workdir"]})"
              # A row of a table elsewhere ends in the runner it lives on.
              line << "  runner #{row["runner"]}" if row["runner"]
              row["ready_line"] ? "#{line}\n    #{row["ready_line"]}" : line
            end
        end
      end
    end
  end
end
