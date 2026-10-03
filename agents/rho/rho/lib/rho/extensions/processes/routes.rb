module Rho
  module Extensions
    module Processes
      # The person's door to the processes a loop started: the same table the tools fill — and
      # the tables of the runners the followed hosts are bound to, read through
      # `Processes.list`/`log`.
      module Routes
        LOG_LINES = 100
        LOG_LINES_MAX = 2000
        LOG_BYTES_MAX = 64 * 1024

        class << self
          def register(api, table)
            api.register_route("GET", "/processes") do |request, ctx|
              [200, document(table, ctx, runner: ControlServer.query(request)["runner"])]
            end
            api.register_route("POST", "/processes/stop") { |request, _ctx| stop(table, request) }
            api.register_route("GET", "/processes/log") { |request, ctx| log(table, request, ctx) }
          end

          # The rows: this machine's, then every followed host's runner's
          # (now the rows themselves), each naming
          # the runner it lives on; a runner that could not answer is one
          # `unreachable` entry rather than a listing that looks empty.
          # `runner:` narrows the read to one table.
          def document(table, ctx = nil, runner: nil)
            return one_runner(table, ctx, runner) if runner

            rows = table.nil? ? [] : table.snapshots.map(&:to_h)
            unreachable = []
            remote_runners(ctx).each do |remote|
              rows += Processes.list(ctx, remote, table)
            rescue Remote::Unreachable => error
              unreachable << { runner: remote, error: error.key }
            end
            { processes: rows, orphans: table.nil? ? [] : table.take_orphans, unreachable: unreachable }
          end

          # The runners the followed hosts are bound to that are not this
          # process: nil bindings and this daemon's own row are not "remote".
          def remote_runners(ctx)
            return [] if ctx.nil?

            ctx.host_bindings.filter_map do |binding|
              runner = binding[:runner]
              runner unless runner.nil? || ctx.own_runner?(runner)
            end.uniq
          end

          # Signal-only on the reactor: TERM now, 202 with the row stopping;
          # the grace and the KILL run on the table's own thread, so a server
          # ignoring TERM never holds the control surface. `rho kill` polls.
          def stop(table, request)
            id = ControlServer.json_body(request)["id"].to_s
            return Rho::Daemon::Refusal.malformed("id is required") if id.empty?

            if table.nil?
              return Rho::Daemon::Refusal.new(status: 503, code: "processes_unavailable",
                message: "this daemon has no process table")
            end

            snapshot = table.stop(id, by: "user", wait: false)
            [snapshot.live? ? 202 : 200, { process: snapshot.to_h }]
          rescue Rho::Processes::NotFound => error
            Rho::Daemon::Refusal.new(status: 404, code: "process_not_found", message: error.message)
          rescue Rho::Processes::Error => error
            Rho::Daemon::Refusal.new(status: 409, code: "process_error", message: error.message)
          end

          # One row's tail. `runner=` names the table; without it this
          # machine's is read first, and an id it does not know is asked of
          # the ONE runner the followed hosts are bound to — with several, the
          # 404 says which flag picks one.
          def log(table, request, ctx = nil)
            query = ControlServer.query(request)
            id = query["id"].to_s
            return Rho::Daemon::Refusal.malformed("id is required") if id.empty?

            lines = Integer(query.fetch("lines", LOG_LINES), exception: false)
            return Rho::Daemon::Refusal.malformed("lines must be an integer") if lines.nil?

            document = log_document(table, ctx, query["runner"], id, lines)
            return not_found(id, ctx, query["runner"]) if document.nil?

            [200, document.except(:snapshot)]
          rescue Remote::Unreachable => error
            Rho::Daemon::Refusal.new(status: 502, code: "runner_unreachable", message: error.message)
          end

          # THE ONE FUNCTION behind the door and the person's tool (`Tools::ProcessLog`): the live
          # row's tail, else the exit the registry remembers with the file's tail — the file is
          # what keeps the output once the row is gone — else nil.
          def read_log(table, id, lines)
            count = lines.clamp(1, LOG_LINES_MAX)
            row = table&.row(id)
            if row
              snapshot = row.snapshot
              text = row.output.lines(count, max_bytes: LOG_BYTES_MAX)
            else
              snapshot = table&.exit_of(id)
              return nil if snapshot.nil?

              text = Rho::Processes::Output.tail(snapshot.log_path, count, max_bytes: LOG_BYTES_MAX)
            end
            { process: snapshot.to_h, path: snapshot.log_path, lines: text.lines.map(&:chomp), snapshot: snapshot }
          end

          private

            def one_runner(table, ctx, runner)
              { processes: Processes.list(ctx, runner, table), orphans: [], unreachable: [] }
            rescue Remote::Unreachable => error
              { processes: [], orphans: [], unreachable: [{ runner: runner, error: error.key }] }
            end

            def log_document(table, ctx, runner, id, lines)
              return Processes.log(ctx, runner, id, lines, table) if runner

              local = Routes.read_log(table, id, lines)
              return local if local

              remote = remote_runners(ctx)
              remote.one? ? Processes.log(ctx, remote.first, id, lines, table) : nil
            end

            def not_found(id, ctx, runner)
              several = runner.nil? && remote_runners(ctx).length > 1
              message = several ? "no process #{id} here; name a runner's table with --runner" : "no process #{id}"
              Rho::Daemon::Refusal.new(status: 404, code: "process_not_found", message: message)
            end
        end
      end
    end
  end
end
