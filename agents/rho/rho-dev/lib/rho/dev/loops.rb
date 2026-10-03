require "json"

module Rho
  module Dev
    # THE LOOP VERBS: a loop read, attached, repaired, decided, paused,
    # resumed, grown and deleted from a terminal, and what it answered.
    # Each is one core primitive and a few lines.
    module Loops
      def self.register(api)
        api.register_command("loops",
          description: "List the agent loops this daemon is following (--server for the workspace's)",
          options: {
            server: { type: :boolean, default: false, desc: "Ask the workspace instead of this daemon's own followers" },
            side: { type: :boolean, default: false, desc: "List the side conversations this daemon opened (hidden by default)" },
            status: { type: :string, desc: "With --server: a comma-separated set of loop statuses" },
            attention: { type: :string, desc: "With --server: `any` for the loops needing a person" },
          }, &method(:loops))
        api.register_command("result", usage: "result LOOP_ID",
          description: "Print what a loop answered", &method(:result))
        api.register_command("pause", usage: "pause LOOP_ID",
          description: "Pause a loop after its in-flight work (--force aborts it now)",
          options: { force: { type: :boolean, default: false,
                              desc: "Abort running model steps now; they re-queue on resume" } },
          &method(:pause))
        api.register_command("resume", usage: "resume LOOP_ID",
          description: "Resume a paused loop", &method(:resume))
        api.register_command("answer", usage: "answer LOOP_ID TASK_KEY CONTENT",
          description: "Answer a question a loop is waiting on",
          options: {
            outcome: { type: :string, desc: %(Settle it "failed" rather than "completed") },
            token: { type: :string,
                     desc: "The resolution_token an append receipt returned, for an await a client authored" },
          }, &method(:answer))
        api.register_command("task", usage: "task LOOP_ID TASK_KEY",
          description: "One task, whole: its output, its question, its arguments", &method(:task))
        api.register_command("append", usage: "append LOOP_ID",
          description: "Grow a loop: place steps after its answer, from a JSON file (-f FILE; - for stdin)",
          options: { file: { type: :string, aliases: "-f", desc: "A JSON array of steps, as the append door reads them" } },
          &method(:append))
        api.register_command("phases", usage: "phases LOOP_ID",
          description: "How far a loop has come: its phases, the one in flight, background work and spend",
          &method(:phases))
        api.register_command("attach", usage: "attach ID",
          description: "Start following a loop this daemon did not place; with --conversation, a conversation " \
                       "by its own id (a row this daemon forgot, a thread reopened) on its own feed",
          options: { live: { type: :boolean, default: true,
                             desc: "Subscribe to the live stream as well as the lifecycle" },
                     conversation: { type: :boolean, default: false,
                                     desc: "ID names a conversation, not a loop" } },
          &method(:attach))
        # `--model` re-runs a failed model step on another model — the way
        # on for a step a provider declined when no fallback took it.
        api.register_command("retry", usage: "retry LOOP_ID [TASK_KEY]",
          description: "Re-run a failed task so a halted loop can go on (--model: on another model)",
          options: {
            model: { type: :string, desc: "Re-run a failed model step on this model, as provider/reference" },
            effort: { type: :string, desc: "The reasoning effort for --model's model (default: that model's own)" },
          }, &method(:retry))
        api.register_command("abandon", usage: "abandon LOOP_ID [TASK_KEY]",
          description: "Give up on a failed task so the loop can move past it", &method(:abandon))
        # THE SESSION GRANT: `--always` approves AND
        # grants the call's shape for the rest of this daemon's life;
        # `--match PREFIX` grants a word-bounded prefix instead and implies
        # `--always`. `rho rules` lists what stands. The usage names the
        # POSITIONALS alone (exe/rho's Arity counts its words; the flags
        # are Thor options) — the usage-line law, `dev_cli_test`.
        api.register_command("approve", usage: "approve LOOP_ID TASK_KEY",
          description: "Let a tool call the loop is holding for approval run (--always: and allow its exact " \
                       "text, or --match PREFIX its family, for the rest of this daemon's life)",
          options: {
            always: { type: :boolean, default: false,
                      desc: "Also grant the call's shape — the exact `command` of bash/start_process, the exact " \
                            "`path` of write/edit, any other tool whole — until the daemon's next boot" },
            match: { type: :string,
                     desc: "Grant a prefix instead of the exact text (`npm` → `npm *`; a directory → `dir/*`); " \
                           "implies --always" },
          }, &method(:approve))
        api.register_command("deny", usage: "deny LOOP_ID TASK_KEY [REASON]",
          description: "Refuse a held tool call; the reason is what the model reads next",
          &method(:deny))
        api.register_command("rules",
          description: "The approval grants this daemon holds for the session, and the declared list's size",
          &method(:rules))
        api.register_command("delete", usage: "delete LOOP_ID",
          description: "Remove a finished loop from every surface (stop it first)", &method(:delete))
      end

      class << self
        # The local followers, or with `--server` the workspace's: a
        # restarted daemon follows nothing, and the local list alone made
        # a restart look like an empty machine.
        def loops(cli, _args, options)
          server = options[:server]
          rows = cli.core.loops(scope: (server ? "server" : nil), status: options[:status],
            attention: options[:attention], side: options[:side] == true)
          if rows.empty?
            cli.out.puts server ? "(this workspace holds no matching loops)" :
              "(this daemon is following no loops)"
          end
          rows.each { |row| cli.out.puts loop_line(row) }
          rows
        end

        # `watch` says where a run got to; this says what it produced.
        def result(cli, (public_id), _options)
          row = cli.core.result(public_id)
          cli.out.puts "status:    #{row.fetch("status")}"
          output = row["output"]
          # A loop with no deliverable is an honest answer, not an empty
          # one; saying so beats a blank line.
          if output.nil?
            cli.out.puts "output:    (none — this loop resolved no deliverable)"
          else
            cli.out.puts output
          end
          row
        end

        def pause(cli, (public_id), options)
          print_lifecycle(cli, cli.core.pause(public_id, force: options[:force]))
        end

        def resume(cli, (public_id), _options)
          print_lifecycle(cli, cli.core.resume(public_id))
        end

        # A model's own `ask` is tokenless: without `--token` the daemon
        # commits it on the executor plane as its own inbox row, falling to
        # the member door once for a row that is nobody's; a
        # client-authored await needs the `resolution_token` its append
        # receipt returned, or the kernel refuses `stale_claim`. The line
        # names the door that settled it.
        DOORS = { "executor" => "executor plane", "member" => "member door" }.freeze

        def answer(cli, (public_id, task_key, content), options)
          answered = cli.core.answer(public_id, task_key, content, outcome: options[:outcome], token: options[:token])
          door = DOORS.fetch(answered.fetch("door"))
          cli.out.puts "answered:  #{task_key} (#{door})"
          answered
        end

        # One task, whole: the question an await is asking, the arguments a
        # tool call was given.
        def task(cli, (public_id, task_key), _options)
          row = cli.core.task(public_id, task_key)
          cli.print_task(row)
          cli.out.puts row["output"] if row["output"]
          row
        end

        # GROW A LOOP: the steps come from a file as the door reads them,
        # so a person can place a phase the way a client would.
        def append(cli, (public_id), options)
          path = options[:file].to_s
          raise Rho::Error, "append needs -f FILE, a JSON array of steps" if path.empty?

          steps = JSON.parse(path == "-" ? $stdin.read : File.read(path, encoding: "UTF-8"))
          receipt = cli.core.append(public_id, steps: steps)
          cli.out.puts "appended:  #{Array(receipt["accepted_task_keys"]).join(", ")}"
          cli.out.puts "answer:    #{receipt["deliverable_task_key"]}" if receipt["deliverable_task_key"]
          receipt
        rescue JSON::ParserError, SystemCallError => error
          raise Rho::Error, "cannot read steps from #{path}: #{error.message}"
        end

        # How far along, one line per phase; `>` marks the one in flight.
        # `phases`, never `progress`: that word is the ephemeral feed
        # `rho watch` prints, and one word has one meaning.
        def phases(cli, (public_id), _options)
          row = cli.core.phases(public_id)
          phases = row.fetch("phases")
          cli.out.puts "(no phases yet)" if phases.empty?
          phases.each_with_index do |phase, index|
            mark = index == row["current"] ? ">" : " "
            cli.out.puts "#{mark} #{phase.fetch("label")}  #{phase.fetch("done")}/#{phase.fetch("total")}  #{phase.fetch("status")}"
          end
          row.fetch("background").each do |task|
            mailed = task["mailed_at"] ? "  (mailed #{task["mailed_at"]})" : ""
            cli.out.puts "background: #{task.fetch("key")} #{task.fetch("status")}#{mailed}"
          end
          spend = row.fetch("spend")
          cli.out.puts "spend:     #{spend_line(spend)}"
          # Whose spend was whose, once a step re-ran on another model (the
          # declared fallback after a refusal, a result-mail switch).
          by_model = spend.fetch("by_model", {})
          by_model.each { |model, part| cli.out.puts "  #{model}  #{spend_line(part)}" } if by_model.length > 1
          row
        end

        # After a restart, or on a second machine watching work the first
        # one started. `--conversation` is the core's
        # conversation arm: one line naming what is followed now.
        def attach(cli, (public_id), options)
          if options[:conversation]
            document = cli.core.attach(public_id, live: options.fetch(:live, true), host_type: "conversation")
            cli.out.puts "#{document.fetch("conversation").fetch("public_id")}  conversation  followed"
            return document
          end

          document = cli.core.attach(public_id, live: options.fetch(:live, true))
          cli.out.puts loop_line(document.fetch("loop"))
          document
        end

        # The key is optional: the daemon reads the trace with the kernel's
        # own rule and refuses when two tasks qualify. The line names the
        # model when one was asked for.
        def retry(cli, (public_id, task_key), options)
          model = options[:model]
          row = cli.core.retry(public_id, task_key, model: model, reasoning_effort: options[:effort])
          print_repair(cli, "retried:", row, on: model)
        end

        def abandon(cli, (public_id, task_key), _options)
          print_repair(cli, "abandoned:", cli.core.abandon(public_id, task_key))
        end

        # THE APPROVAL VERBS: the key is always named — the
        # ASKING line printed it, and a decision is about ONE call whose
        # arguments the person read (`rho task`). `--always`/`--match`
        # ride the body as themselves; the daemon
        # derives the grant and answers it beside the task.
        def approve(cli, (public_id, task_key), options)
          needs_key("approve", task_key)
          decided(cli, "approved:", cli.core.approve(public_id, task_key, always: options[:always], match: options[:match]))
        end

        def deny(cli, (public_id, task_key, reason), _options)
          needs_key("deny", task_key)
          decided(cli, "denied:", cli.core.deny(public_id, task_key, reason: reason))
        end

        # THE SESSION GRANTS:
        # numbered, one line each — the shape as the kernel reads it, the
        # time, the loop and the key it was made on, the conversation when
        # there was one — then the declared list's size against the
        # kernel's bound. Every matcher through the one bound.
        def rules(cli, _args, _options)
          document = cli.core.rules
          cli.out.puts "session grants (until the daemon's next boot):"
          grants = Array(document["grants"])
          cli.out.puts "  #{NO_GRANTS}" if grants.empty?
          grants.each_with_index do |grant, index|
            on = [grant["loop"], grant["task_key"]].join(" ")
            conversation = grant["conversation"] ? " (conversation #{grant["conversation"]})" : ""
            cli.out.puts "  #{index + 1}  #{grant_shape(cli, grant.fetch("rule"), pad: true)}   " \
                         "granted #{grant["granted_at"]} on #{on}#{conversation}"
          end
          declared = document.fetch("declared")
          cli.out.puts "declared: #{declared["rules"]} rules, #{thousands(declared["bytes"])} of " \
                       "#{thousands(declared["bound"])} bytes"
          document
        end

        NO_GRANTS = "(no session grants; rho approve LOOP KEY --always adds one)".freeze

        # The record, not the run: `rho stop` is how a run ends.
        def delete(cli, (public_id), _options)
          document = cli.core.delete_loop(public_id)
          cli.out.puts "deleted:   #{document.dig("deleted", "public_id")}"
          document
        end

        # One loop as a line: the id, the status, the ask, the check's
        # count, whether this daemon follows it, its parent when it is a
        # side, the failure reason. Shared with `attach`.
        def loop_line(row)
          parts = ["#{row.fetch("public_id")}  #{row.fetch("status")}"]
          attention = row["attention"]
          parts << "ASKING: #{attention.fetch("reason")}" if attention
          policy = row["until"]
          parts << "until #{Array(policy["checks"]).size}/#{policy["attempts"]}" if policy
          # A server row says whether this daemon is the one following
          # it — the fact a person needs before typing `rho watch`.
          parts << "not followed" if row.key?("followed") && !row.fetch("followed")
          parts << "side of #{row.dig("side", "parent")}" if row["side"]
          parts << row["failure_reason"] if row["failure_reason"]
          parts.join("  ")
        end

        private

          RE_PARKED = "the call's effect profile changed under the park; read `rho task` and decide again".freeze
          SESSION_NOTE = "   (this session; `rho rules` lists it)".freeze

          def needs_key(verb, task_key)
            raise Rho::Error, "#{verb} needs LOOP_ID and TASK_KEY — the key the ASKING line printed" if task_key.to_s.empty?
          end

          def decided(cli, label, document)
            row = document.fetch("task")
            cli.out.puts "#{label}  #{row.fetch("key")}"
            status = row.fetch("status")
            cli.out.puts "status:    #{status}#{status_note(status, row)}"
            print_grant(cli, document["grant"]) if document.key?("grant")
            row
          end

          # THE GRANT LINES: the shape as the kernel
          # reads it; a prefix with the raw-text warning (the grammar has
          # no shell in it); a shape already held in words; a kernel
          # refusal by code — the call ran, the grant did not land — and
          # exit 1, after the lines.
          def print_grant(cli, grant)
            if grant["already"]
              cli.out.puts "granted:   (already granted this session)"
            elsif grant["refused"]
              cli.out.puts "granted:   refused — #{grant["refused"]}: the call ran; the grant did not land"
              raise Rho::Error, "the grant did not land (#{grant["refused"]}); the call ran"
            else
              rule = grant.fetch("rule")
              cli.out.puts "granted:   #{grant_shape(cli, rule)}#{rule["match"] ? SESSION_NOTE : ""}"
              return unless prefix?(rule)

              cli.out.puts "warning:   a prefix grant is raw text — it also allows " \
                           "\"#{cli.bounded(rule["match"].delete_suffix("*"))}anything; …\" on the same line"
            end
          end

          # A text-keyed rule as `tool  key = "text"`, the tool padded to a
          # column under `pad:` (`rho rules`); a whole-tool rule as its
          # name. The matcher is model-authored text: the one bound.
          def grant_shape(cli, rule, pad: false)
            return rule.fetch("tool") unless rule["match"]

            tool = pad ? rule.fetch("tool").ljust(6) : "#{rule.fetch("tool")} "
            "#{tool} #{rule["path"]} = \"#{cli.bounded(rule["match"])}\""
          end

          # An exact grant never carries `*` (the derivation refuses it),
          # so a matcher ending in one is the prefix shape.
          def prefix?(rule) = rule["match"].to_s.end_with?("*")

          def thousands(number) = number.to_s.gsub(/(\d)(?=(\d{3})+\z)/, "\\1,")

          def status_note(status, row)
            case status
            when "needs_approval" then " — #{RE_PARKED}"
            when "failed" then " (#{row.dig("error", "key")})"
            else ""
            end
          end

          def spend_line(spend)
            cost = " — #{spend["cost_amount"]} #{spend["cost_unit"]}".rstrip if spend["cost_amount"]
            "#{spend["input_tokens"]} in, #{spend["output_tokens"]} out#{cost}"
          end

          def print_repair(cli, label, row, on: nil)
            cli.out.puts "#{label}  #{row.fetch("key")}#{on ? " on #{on}" : ""}"
            cli.out.puts "status:    #{row.fetch("status")}"
            row
          end

          def print_lifecycle(cli, loop_row)
            cli.out.puts "loop:      #{loop_row.fetch("public_id")}"
            cli.out.puts "status:    #{loop_row.fetch("status")}"
            loop_row
          end
      end
    end
  end
end
