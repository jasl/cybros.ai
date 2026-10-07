require_relative "../../schedule_commands"

module Rho
  module Extensions
    module Ops
      # Human surfaces share the member-plane resource; no local recurrence
      # state or timer participates in acceptance or progress.
      module JobRoutes
        AUTHORING_FIELDS = %w[prompt rule name model reasoning_effort reasoning_enabled configuration tool_names approval_mode to speaker_public_id].freeze
        PROVENANCE_FIELDS = %w[source_run_public_id source_task_key].freeze

        class << self
          def register(api)
            %w[list detail executions].each do |operation|
              path = operation == "list" ? "/conversations/schedules" : "/conversations/schedules/#{operation}"
              api.register_route("GET", path) { |request, ctx| read(request, ctx, operation) }
            end
            %w[create update pause resume cancel].each do |operation|
              api.register_route("POST", "/conversations/schedules/#{operation}") do |request, ctx|
                write(request, ctx, operation)
              end
            end
            api.register_command("jobs", usage: "jobs CONVERSATION_ID ACTION [ARGUMENTS...]",
              description: "Manage delayed and recurring tasks that report to this conversation",
              options: {
                json: { type: :boolean, default: false, desc: "Print JSON" },
                model: { type: :string, desc: "Model for a new scheduled job" },
                workspace: { type: :string, desc: "The conversation's workspace" },
              }, &method(:command))
          end

          def read(request, ctx, operation)
            query = ControlServer.query(request)
            public_id = query.fetch("public_id", "").to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            limit = Integer(query["limit"], exception: false) if query["limit"]
            return Rho::Daemon::Refusal.malformed("limit must be a positive integer") if query["limit"] && !limit&.positive?

            ctx.member_plane(request) do |client, workspace_public_id|
              jobs = client.workspace(workspace_public_id).conversation(public_id).schedules
              case operation
              when "list"
                page = jobs.list(after: query["after"], limit: limit)
                [200, { schedules: page.items.map(&:to_h), pagination: { next_after: page.next_after } }]
              when "detail"
                [200, { schedule: jobs.fetch(query.fetch("job_public_id")).to_h }]
              when "executions"
                page = jobs.executions(query.fetch("job_public_id"), after: query["after"], limit: limit)
                [200, { executions: page.items.map(&:to_h), pagination: { next_after: page.next_after, last_cursor: page.last_cursor } }]
              else
                raise ArgumentError, "unknown scheduled job read: #{operation}"
              end
            end
          rescue KeyError => error
            Rho::Daemon::Refusal.parameter_missing(error.key)
          end

          def write(request, ctx, operation)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
              public_id = body.fetch("public_id").to_s
              next Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

              workspace = client.workspace(workspace_public_id)
              jobs = workspace.conversation(public_id).schedules
              fields = body.slice(*AUTHORING_FIELDS).transform_keys(&:to_sym)
              case operation
              when "create"
                fields[:prompt] = body.fetch("prompt")
                fields[:rule] = body.fetch("rule")
                fields[:model] ||= ctx.conversation_model(public_id, workspace)
                fields.delete(:model) if fields[:model].nil?
                names = ctx.conversation_tool_names(public_id, workspace, client: client, to: fields[:to], tool_names: fields[:tool_names])
                next names if names in Rho::Daemon::Refusal

                fields[:tool_names] = names unless names.nil?
                fields.merge!(body.slice(*PROVENANCE_FIELDS).transform_keys(&:to_sym))
                created = jobs.create(**fields, idempotency_key: body.fetch("idempotency_key"))
                [201, { schedule: created.schedule.to_h, replayed: created.replayed? }]
              when "update"
                if fields.key?(:tool_names)
                  to = fields.key?(:to) ? fields[:to] : jobs.fetch(body.fetch("job_public_id")).answering_user_public_id
                  names = ctx.conversation_tool_names(public_id, workspace, client: client, to: to, tool_names: fields[:tool_names])
                  next names if names in Rho::Daemon::Refusal

                  fields[:tool_names] = names
                end
                row = jobs.update(body.fetch("job_public_id"), **fields, expected_lock_version: body.fetch("expected_lock_version"))
                [200, { schedule: row.to_h }]
              when "pause", "resume", "cancel"
                [200, { schedule: jobs.public_send(operation, body.fetch("job_public_id")).to_h }]
              else
                raise ArgumentError, "unknown scheduled job command: #{operation}"
              end
            end
          rescue KeyError => error
            Rho::Daemon::Refusal.parameter_missing(error.key)
          end

          def command(cli, args, options)
            public_id, *words = args
            raise Rho::Error, "Use rho jobs CONVERSATION_ID #{Rho::ScheduleCommands::USAGE}" if public_id.to_s.empty?

            command = Rho::ScheduleCommands.parse(words.join(" "), now: Time.now.to_f)
            result = Rho::ScheduleCommands.execute(cli.core, public_id, command,
              model: options[:model], workspace_public_id: options[:workspace])
            cli.out.puts(options[:json] ? JSON.generate(result) : Rho::ScheduleCommands.render(command, result))
            result
          end
        end
      end
    end
  end
end
