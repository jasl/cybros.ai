module Rho
  module Extensions
    module Handoff
      # The terminal bodies. Each takes the terminal (`Rho::Cli::Terminal`) —
      # the core client behind `cli.core`, the budgets and the printer — and speaks to the daemon
      # through it; `runners use` alone touches a file, the person's own
      # settings, from this process: the daemon writes settings never.
      module Commands
        LEGEND = "* selected in settings  = this machine's own".freeze

        class << self
          # One line per runner discovery lists: the marks, the id, the
          # name, the kernel's presence word, the announced root, the tool
          # count, the followed hosts bound to it and a byte collision by
          # name; the legend closes the listing.
          def runners(cli, args, options)
            return use(cli, args, options) if args.first == "use" || options[:none]

            document = listing(cli)
            rows = Array(document["runners"])
            if rows.empty?
              cli.out.puts "(no runner is eligible for this profile)"
              return rows
            end

            now = Time.now
            rows.each { |row| cli.out.puts runner_line(row, now) }
            cli.out.puts LEGEND
            rows
          end

          # `rho handoff HOST EXECUTOR` — a RECOVERY verb: for
          # a runner that died or was replaced; a conversation ordinarily
          # keeps the runner it was created with. The move, then the
          # daemon's tree-sync warning when the trees differ (ONE line), then the three-state slot the kernel's `runner:`
          # read prints (nothing when online). A refusal — the collision,
          # the kernel's — is one sentence, exit 1.
          def handoff(cli, (host, executor), _options)
            answer = cli.core.parse(cli.core.post(cli.core.require_daemon, "/handoff",
              { "public_id" => host, "executor_public_id" => executor }, budget: Rho::Core::Budget::KERNEL_ROUND_TRIP))
            raise Rho::Error, cli.core.failure_message(answer) if answer.key?("error")

            runner = answer["runner"]
            cli.out.puts "handed off: #{answer.dig("host", "public_id")} → #{runner&.dig("executor_public_id")} " \
                         "(was #{answer["previous"] || "none"})"
            cli.out.puts "warning:   #{answer["warning"]}" if answer["warning"]
            line = runner && Rho::RunnerSlot.line(runner)
            cli.out.puts "runner:    #{line}" if line
            answer
          end

          private

            # THE SELECTION IS THE PERSON'S FILE (correction (f)): the id is
            # validated against the daemon's listing — a runner this profile
            # may not address is refused with the verb that lists them —
            # then applied through the daemon's settings owner. The selection
            # affects new conversations; existing bindings keep their runner.
            def use(cli, args, options)
              document = listing(cli)
              if options[:none]
                cli.core.update_settings("runner" => nil)
                cli.out.puts "runner: none (this machine's own runner when it has one)"
                return nil
              end

              id = args[1].to_s
              raise Rho::Error, "which runner? `rho runners use ID` (`rho runners` lists them), or --none" if id.empty?
              unless Array(document["runners"]).any? { |row| row["public_id"] == id }
                raise Rho::Error, "#{id} is not a runner this profile may address; `rho runners` lists them"
              end

              cli.core.update_settings("runner" => id)
              cli.out.puts "runner: #{id} (new conversations start on it)"
              id
            end

            def listing(cli)
              document = cli.core.parse(cli.core.get(cli.core.require_daemon, "/runners", budget: Rho::Core::Budget::KERNEL_ROUND_TRIP))
              raise ConnectionError, cli.core.failure_message(document) if document.key?("error")

              document
            end

            def runner_line(row, now)
              marks = row["selected"] ? "* " : (row["own"] ? "= " : "  ")
              line = "#{marks}#{row["public_id"]}  #{row["display_name"]}  " \
                     "#{Rho::RunnerSlot.presence_word(row["presence"], row["last_seen_at"], now: now)}  " \
                     "root #{row["root"] || "-"}  tools #{Array(row["tools"]).length}"
              bound = Array(row["bound_hosts"])
              line += "  bound: #{bound.join(", ")}" unless bound.empty?
              line += "  conflict: #{row["conflict"]}" if row["conflict"]
              line
            end
        end
      end
    end
  end
end
