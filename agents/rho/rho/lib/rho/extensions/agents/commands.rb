module Rho
  module Extensions
    module Agents
      # THE VERB FAMILY, the
      # `skills` family's shape: each verb one route, the printed lines
      # the command's. A refusal is the daemon's sentence, one line, exit 1.
      module Commands
        USAGE = "`rho agents`, `rho agents sync`, `rho agents publish NAME`, `rho agents rm NAME`".freeze
        NO_MODEL = "—".freeze
        NONE = "none".freeze

        class << self
          def agents(cli, (verb, *rest), _options)
            case verb
            when nil then list(cli)
            when "sync" then sync(cli)
            when "publish" then publish(cli, rest.first)
            when "rm" then remove(cli, rest.first)
            else raise Rho::Error, "agents takes sync, publish or rm: #{USAGE}"
            end
          end

          # The two homes, then the scan's skipped files. Read-only.
          def list(cli)
            document = cli.core.parse(cli.core.get(cli.core.require_daemon, "/agents", budget: Rho::Core::Budget::KERNEL_ROUND_TRIP))
            raise Rho::Error, cli.core.failure_message(document) if document.key?("error")

            root = document["root"]
            agents = document.fetch("agents")
            heading = root ? "(#{Rho::Agents::DIRECTORIES.join(", ")} under #{root})" : "(no root set; `rho env ROOT` points the daemon at one)"
            print_section(cli, "instance/  #{heading}", agents.fetch("instance"), root)
            print_section(cli, "nexus/  (published under the steward; every agent of this steward may spawn them)",
              agents.fetch("nexus"), root)
            skipped = document.fetch("skipped")
            unless skipped.empty?
              cli.out.puts "skipped:"
              skipped.each { |row| cli.out.puts "  #{relative(row.fetch("path"), root)}: #{row.fetch("reason")}" }
            end
            document
          end

          def sync(cli)
            response = cli.core.post(cli.core.require_daemon, "/agents/sync", {}, budget: Rho::Core::Budget::KERNEL_ROUND_TRIP)
            document = cli.core.parse(response)
            raise Rho::Error, cli.core.failure_message(document) unless response.code.to_i == 200

            declared, removed = document.values_at("declared", "removed")
            cli.out.puts "declared: #{counted(declared)}   removed: #{counted(removed)}   skipped: #{document.fetch("skipped")}"
            document
          end

          def publish(cli, name)
            raise Rho::Error, "agents publish needs NAME" if name.to_s.empty?

            response = cli.core.post(cli.core.require_daemon, "/agents/publish", { "name" => name },
              budget: Rho::Core::Budget::KERNEL_ROUND_TRIP)
            document = cli.core.parse(response)
            raise Rho::Error, cli.core.failure_message(document) unless response.code.to_i == 200

            agent = document.fetch("agent")
            path = relative(document.fetch("path"), document["root"])
            cli.out.puts "published: @#{agent.fetch("handle")} (#{agent.fetch("agent_identifier")}) from #{path}"
            document
          end

          def remove(cli, name)
            raise Rho::Error, "agents rm needs NAME" if name.to_s.empty?

            response = cli.core.post(cli.core.require_daemon, "/agents/rm", { "name" => name },
              budget: Rho::Core::Budget::KERNEL_ROUND_TRIP)
            document = cli.core.parse(response)
            raise Rho::Error, cli.core.failure_message(document) unless response.code.to_i == 200

            removed = document.fetch("removed")
            line = "removed: @#{removed.fetch("handle")} (#{removed.fetch("agent_identifier")})"
            file = document["file"]
            file &&= relative(file, document["root"])
            line += "; the file #{file} still defines it — delete the file or it returns at the next sync" if file
            cli.out.puts line
            document
          end

          private

            def print_section(cli, heading, rows, root)
              cli.out.puts heading
              cli.out.puts "  (none)" if rows.empty?
              rows.each do |row|
                cli.out.puts "  #{row_line(row, root)}"
                cli.out.puts "    #{relative(row.fetch("path"), root)}" if row["path"]
              end
            end

            def row_line(row, root)
              tools = Array(row.fetch("tools"))
              parts = ["@#{row.fetch("handle")}", row.fetch("name"), row.fetch("description"),
                       "model: #{row["model"] || NO_MODEL}", "fallback: #{row["fallback"] || NO_MODEL}",
                       "tools: #{tools.empty? ? NONE : tools.join(", ")}"]
              parts << "from: @#{row["from"]}" if row["from"]
              parts << "shadowed by #{relative(row["shadowed_by"], root)}" if row["shadowed_by"]
              parts.join("   ")
            end

            def relative(path, root)
              root && path.start_with?("#{root}/") ? path.delete_prefix("#{root}/") : path
            end

            def counted(names) = names.empty? ? "0" : "#{names.length} (#{names.join(", ")})"
        end
      end
    end
  end
end
