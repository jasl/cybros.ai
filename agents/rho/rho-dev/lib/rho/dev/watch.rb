module Rho
  module Dev
    # THE WATCH COMPOSITION (a composition is the surface's, never the core's): the once-per-change table over `core.loop_row`,
    # the shared renderers, and the poll's four exits.
    module Watch
      # The daemon is following over a socket, so this is how often a
      # HUMAN's terminal redraws — not how fresh the data is.
      WATCH_INTERVAL = 1.0

      def self.register(api)
        api.register_command("watch", usage: "watch LOOP_ID",
          description: "Follow one loop's tasks until it finishes",
          options: {
            timeout: { type: :numeric, desc: "Give up after this many seconds (default: watch until it ends)" },
          }.merge(Rho::Dev::STREAM_OPTIONS),
          &method(:watch))
      end

      class << self
        # The follow half of `do`, as its own verb: a watcher that died
        # left the loop running, and this re-attaches to it by id.
        def watch(cli, (public_id), options)
          poll(cli, public_id, deadline: options[:timeout],
            reasoning: options[:reasoning] == true, stream: options.fetch(:stream, true) != false)
        end

        # THE ONCE-PER-CHANGE TABLE, with the model's words as they
        # accumulate. It polls the daemon's row (`core.loop_row`), not the
        # kernel: the snapshot is as fresh as the socket, costs no
        # member-plane traffic, and a dying watcher leaves the work
        # untouched. Only what changed prints.
        #
        # It KEEPS the poll rather than becoming a pure stream, because
        # three things it prints come from the snapshot and nothing pushes
        # them — `until.checks`, the runner-wait probe (a task read per
        # dispatched row) and the inbox rows — and a loop quiet for thirty
        # seconds while a check runs pushes no frame at all. `rho follow`
        # is the delta-grained view of the same host.
        #
        # `stream` prints the reply as it accumulates (`--no-stream` to
        # leave the table alone); `reasoning` adds the second channel, off
        # by default. Neither ever enters `seen`: the text is not a task,
        # and the printer holds its own position.
        def poll(cli, public_id, interval: WATCH_INTERVAL, deadline: nil, reasoning: false, stream: true,
                 clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          cli = Rho::Dev.terminal(cli)
          started = clock.call
          seen = {}
          checks_seen = {}
          status = nil
          row = nil
          loop do
            row = cli.core.loop_row(public_id)
            status = row["status"]
            cli.report_tasks(row, seen)
            cli.report_todo(row, seen)
            cli.report_runner_waits(row, seen)
            cli.report_checks(row, checks_seen)
            cli.report_frames(row, seen)
            cli.report_attention(row)
            cli.report_asks_once(seen)
            cli.out.partial(row["reasoning"], channel: :reasoning) if reasoning
            cli.out.partial(row["text"], length: row["text_length"]) if stream
            break if row["complete"]
            raise Rho::Error, "timed out watching #{public_id}" if deadline && (clock.call - started) > deadline

            sleep(interval)
          end
          cli.out.puts "status:    #{status}"
          # A turn-shaped `failed` is a LEVEL, not the end: the
          # loop is holding for a person, and the verb that answers reopens it.
          if status == "failed" && !CybrosAgent::Api::LOOP_TERMINAL_STATUSES.include?(row["loop_status"])
            cli.out.puts "holding:   `rho retry #{public_id}` or `rho answer #{public_id} …` reopens it"
          end
          report_background(cli, row, public_id) if status == "completed"
          status
        end

        private

          # A BACKGROUND TASK MAY OUTLIVE ITS TURN: every task still live when the turn-shaped `completed`
          # landed with the loop running on is background by construction —
          # the reply is final — so this reads the table, never a flag. Its
          # answer reaches the next turn as kernel mail, which `mailed`
          # reports.
          def report_background(cli, row, public_id)
            return if CybrosAgent::Api::LOOP_TERMINAL_STATUSES.include?(row["loop_status"])

            Array(row["tasks"]).each do |task|
              next if CybrosAgent::Api::TASK_TERMINAL_STATUSES.include?(task.fetch("status"))

              cli.out.puts "background: #{task.fetch("task_key")} #{task.fetch("status")} — its result reaches " \
                "the next turn; rho watch #{public_id} follows"
            end
          end
      end
    end
  end
end
