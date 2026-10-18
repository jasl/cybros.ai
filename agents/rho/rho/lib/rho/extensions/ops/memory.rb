require_relative "../../memory_commands"
require_relative "../../speakers"

module Rho
  module Extensions
    module Ops
      # This surface forwards database memory operations. It never reads or
      # writes a filesystem path, and conditional writes retain Nexus's CAS.
      module Memory
        class << self
          def register(api)
            api.register_route("GET", "/conversations/memory") { |request, ctx| list(request, ctx) }
            %w[read write edit delete grep].each do |operation|
              api.register_route("POST", "/conversations/memory/#{operation}") do |request, ctx|
                operate(request, ctx, operation)
              end
            end
            api.register_route("POST", "/conversations/memory_context") { |request, ctx| bind(request, ctx) }
            api.register_command("memory", usage: "memory CONVERSATION_ID ACTION [ARGUMENTS...]",
              description: "Manage database memory with logical file paths",
              options: { json: { type: :boolean, default: false, desc: "Print JSON" },
                speaker: { type: :string, desc: "Speaker public UUID for memory" } }, &method(:command))
          end

          def list(request, ctx)
            query = ControlServer.query(request)
            public_id = query.fetch("public_id", "").to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            ctx.member_plane(request) do |client, workspace_public_id|
              conversation = client.workspace(workspace_public_id).conversation(public_id)
              rows = memory_door(client, conversation, ctx, speaker_public_id: query["speaker_public_id"]).list
              rows = rows.select { |row| row.path.start_with?(query.fetch("path")) } if query["path"]
              [200, { memory: rows.map(&:to_h) }]
            end
          end

          def operate(request, ctx, operation)
            with_conversation(request, ctx) do |conversation, body, client|
              memory = memory_door(client, conversation, ctx, speaker_public_id: body["speaker_public_id"])
              case operation
              when "read"
                [200, { memory: memory.read(body.fetch("path")).to_h }]
              when "write"
                row = memory.write(body.fetch("path"), body.fetch("content"), **expected(body))
                [201, { memory: row.to_h }]
              when "edit"
                row = memory.edit(path: body.fetch("path"), old_text: body.fetch("old_text"), new_text: body.fetch("new_text"), **expected(body))
                [200, { memory: row.to_h }]
              when "delete"
                memory.delete(body.fetch("path"), **expected(body))
                [200, { deleted: { path: body.fetch("path") } }]
              when "grep"
                result = memory.grep(pattern: body.fetch("pattern"), path: body["path"],
                  ignore_case: body.fetch("ignore_case", false), limit: body["limit"])
                [200, { result: result.to_h }]
              else
                raise ArgumentError, "unknown memory operation: #{operation}"
              end
            end
          end

          def bind(request, ctx)
            with_conversation(request, ctx) do |conversation, body|
              [200, { conversation: conversation.set_memory_context(memory_context: body.fetch("memory_context")).to_h }]
            end
          end

          def command(cli, args, options)
            public_id, *words = args
            raise Rho::Error, "Use rho memory CONVERSATION_ID #{Rho::MemoryCommands::USAGE}" if public_id.to_s.empty?

            action = Rho::MemoryCommands.parse(words.join(" "))
            result = Rho::MemoryCommands.execute(cli.core, public_id, action, speaker_public_id: options[:speaker])
            cli.out.puts(options[:json] ? JSON.generate(result) : Rho::MemoryCommands.render(action, result))
            result
          end

          private

            def memory_door(client, conversation, ctx, speaker_public_id:)
              if speaker_public_id.nil? && conversation.fetch.answering_user_public_id == ctx.own_user_public_id
                # Main conversations address the owner. A Bot's management call
                # has no current participant, so it must select one explicitly.
                speaker_public_id = Speakers.owner(client: client, agent_public_id: ctx.own_user_public_id).public_id
              end
              conversation.memory(speaker_public_id: speaker_public_id)
            end

            def with_conversation(request, ctx)
              ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
                id = body.fetch("public_id").to_s
                next Rho::Daemon::Refusal.malformed("public_id is required") if id.empty?

                yield client.workspace(workspace_public_id).conversation(id), body, client
              end
            rescue KeyError => error
              Rho::Daemon::Refusal.parameter_missing(error.key)
            end

            def expected(body)
              { expected_public_id: body.fetch("expected_public_id"), expected_lock_version: body.fetch("expected_lock_version") }
            end
        end
      end
    end
  end
end
