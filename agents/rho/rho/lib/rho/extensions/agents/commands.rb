module Rho
  module Extensions
    module Agents
      module Commands
        class << self
          def agents(cli, (verb, *rest), _options)
            case verb
            when nil
              document = get(cli, "/agents")
              cli.out.puts "Bots"
              cli.out.puts "  (none)" if document.fetch("bots").empty?
              document.fetch("bots").each do |row|
                cli.out.puts "  @#{row.fetch("handle")}  #{row.fetch("display_name", row.fetch("name"))}  Preset: #{row["preset_name"] || "another application"}"
              end
              document
            when "duplicate"
              source, name, audience = rest
              raise Rho::Error, "agents duplicate needs SOURCE and NAME" if source.to_s.empty? || name.to_s.empty?

              document = post(cli, "/agents/duplicate", { "source_name" => source, "name" => name, "audience" => audience }.compact)
              cli.out.puts "created: @#{document.fetch("agent").fetch("handle")}"
              document
            when "rm"
              raise Rho::Error, "agents rm needs NAME" if rest.first.to_s.empty?

              document = post(cli, "/agents/rm", { "name" => rest.first })
              cli.out.puts "removed: @#{document.fetch("removed").fetch("handle")}"
              document
            else
              raise Rho::Error, "agents takes duplicate or rm; use presets for configuration import and export"
            end
          end

          def bots(cli, (verb, identifier, conversation), options)
            unless %w[current new resume history].include?(verb)
              raise Rho::Error, "bots takes current, new, resume or history"
            end
            required(identifier, "bots #{verb} needs BOT (name, @handle or public id)")
            if options[:workspace] && verb != "resume"
              raise Rho::Error, "--workspace belongs to bots resume; new conversations use the Bot's Home Workspace"
            end
            if verb == "resume"
              required(conversation, "bots resume needs BOT and CONVERSATION_ID")
              required(options[:workspace], "bots resume needs --workspace with the conversation's recorded Workspace UUID")
            end
            id = bot_id(cli, identifier)
            return bot_history(cli, id, options) if verb == "history"

            operation = options[:"operation-id"] || SecureRandom.uuid_v7
            # Print before the mutation: an interrupted caller can retry the
            # same command without creating another conversation.
            cli.out.puts "operation: #{operation}"
            cli.out.flush
            document = case verb
            when "current"
              cli.core.ensure_bot_current(agent_public_id: id, operation_id: operation)
            when "new"
              cli.core.new_bot_conversation(agent_public_id: id, operation_id: operation)
            when "resume"
              cli.core.resume_bot_conversation(agent_public_id: id, operation_id: operation,
                conversation_public_id: conversation, workspace_public_id: options.fetch(:workspace))
            else
              raise Rho::Error, "unsupported Bot conversation command"
            end
            bot_locator(cli, "selected", document.fetch("selected"))
            bot_locator(cli, "current", document.fetch("current")) if document.fetch("current") != document.fetch("selected")
            cli.out.puts "replayed: true" if document.fetch("replayed")
            document
          end

          def presets(cli, (verb, *rest), _options)
            case verb
            when nil
              document = get(cli, "/presets")
              document.fetch("presets").each do |row|
                marks = []
                marks << "main" if row.fetch("public_id") == document.fetch("main_preset_public_id")
                marks << "new Bot default" if row.fetch("public_id") == document.fetch("default_bot_preset_public_id")
                marks << "role: #{row.dig("role", "name")}" if row["role"]
                cli.out.puts "#{row.fetch("public_id")}  #{row.fetch("name")}#{marks.empty? ? "" : "  (#{marks.join(", ")})"}"
              end
              document
            when "import"
              document = post(cli, "/presets/import", rest.empty? ? {} : { "names" => rest })
              cli.out.puts "imported: #{document.fetch("imported").length}  skipped: #{document.fetch("skipped").length}"
              document.fetch("skipped").each { |row| cli.out.puts "#{row.fetch("path")}: #{row.fetch("reason")}" }
              document
            when "import-file"
              path = required(rest.first, "presets import-file needs FILE")
              document = post(cli, "/presets/import_document", { "content" => File.read(path, encoding: "UTF-8"),
                "format" => File.extname(path).delete_prefix("."), "filename" => File.basename(path) })
              cli.out.puts "Preset imported"
              document
            when "export"
              id = required(rest.first, "presets export needs PUBLIC_ID")
              document = get(cli, "/presets/export?#{URI.encode_www_form("public_id" => id, "format" => rest[1] || "md")}")
              cli.out.print document.fetch("content")
              document
            when "duplicate"
              id = required(rest.first, "presets duplicate needs PUBLIC_ID and NAME")
              name = required(rest[1], "presets duplicate needs PUBLIC_ID and NAME")
              post(cli, "/presets/duplicate", { "public_id" => id, "name" => name })
            when "rm"
              post(cli, "/presets/rm", { "public_id" => required(rest.first, "presets rm needs PUBLIC_ID") })
            else
              raise Rho::Error, "presets takes import, import-file, export, duplicate or rm"
            end
          rescue SystemCallError, EncodingError => error
            raise Rho::Error, error.message
          end

          private

            def bot_id(cli, identifier)
              rows = get(cli, "/agents").fetch("bots").reject { |row| row["from"] || row["registered"] }
              matches = rows.select do |row|
                if identifier.start_with?("@")
                  row.fetch("handle") == identifier.delete_prefix("@")
                else
                  row.fetch("public_id") == identifier || row.fetch("name") == identifier
                end
              end
              raise Rho::Error, "No editable Bot matches #{identifier}; rho agents lists them" if matches.empty?
              raise Rho::Error, "Several Bots match #{identifier}; use an @handle or public id" if matches.length > 1

              matches.first.fetch("public_id")
            end

            def bot_history(cli, id, options)
              document = cli.core.bot_history(agent_public_id: id, after: options[:after], limit: options[:limit])
              rows = document.fetch("conversations")
              cli.out.puts "(no Bot conversations)" if rows.empty?
              rows.each do |row|
                cli.out.puts "#{row.fetch("public_id")}  workspace: #{row.fetch("workspace_public_id")}  " \
                  "#{row["archived_at"] ? "archived" : "open"}  #{row["title"]}"
              end
              after = document.fetch("pagination")["next_after"]
              cli.out.puts "next: --after #{after}" if after
              document
            end

            def bot_locator(cli, label, locator)
              cli.out.puts "#{label}: #{locator.fetch("public_id")}  workspace: #{locator.fetch("workspace_public_id")}"
            end

            def required(value, message)
              raise Rho::Error, message if value.to_s.empty?

              value
            end

            def get(cli, path)
              response = cli.core.get(cli.core.require_daemon, path, budget: Rho::Core::Budget::KERNEL_ROUND_TRIP)
              read(cli, response)
            end

            def post(cli, path, body)
              response = cli.core.post(cli.core.require_daemon, path, body, budget: Rho::Core::Budget::KERNEL_ROUND_TRIP)
              read(cli, response)
            end

            def read(cli, response)
              document = cli.core.parse(response)
              raise Rho::Error, cli.core.failure_message(document) unless response.code.to_i == 200

              document
            end
        end
      end
    end
  end
end
