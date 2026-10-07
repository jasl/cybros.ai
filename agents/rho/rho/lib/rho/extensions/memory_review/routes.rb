module Rho
  module Extensions
    module MemoryReview
      module Routes
        class << self
          def register(api, observer:)
            api.register_route("GET", "/conversations/memory_review") { |request, ctx| show(request, ctx) }
            %w[enable disable resume].each do |operation|
              api.register_route("POST", "/conversations/memory_review/#{operation}") do |request, ctx|
                write(request, ctx, operation, observer)
              end
            end
            api.register_command("memory-review", usage: "memory-review CONVERSATION_ID [ACTION]",
              description: "Manage memory review: status, enable, disable or resume",
              options: {
                path: { type: :string, desc: "Scoped document, for example user/review.md or group/review.md" },
                model: { type: :string, desc: "Review model; omitted uses the completed reply's model" },
                workspace: { type: :string, desc: "The conversation's workspace" },
                json: { type: :boolean, default: false, desc: "Print JSON" },
              }, &method(:command))
          end

          def show(request, ctx)
            id = ControlServer.query(request).fetch("public_id").to_s
            ctx.member_plane(request) do |client, workspace_public_id|
              review = Rho::MemoryReview.new(workspace: client.workspace(workspace_public_id), conversation_public_id: id)
              [200, { memory_review: review.status }]
            end
          rescue KeyError => error
            Rho::Daemon::Refusal.parameter_missing(error.key)
          end

          def write(request, ctx, operation, observer)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, about, body|
              review = observer.service(ctx, client.workspace(workspace_public_id), body.fetch("public_id").to_s, about)
              result = case operation
              when "enable"
                review.enable(path: body.fetch("path"), model: body["model"])
              when "disable"
                review.disable
              when "resume"
                review.resume
              else
                raise ArgumentError, "unknown memory review operation: #{operation}"
              end
              [200, { memory_review: result }]
            end
          rescue KeyError => error
            Rho::Daemon::Refusal.parameter_missing(error.key)
          end

          def command(cli, args, options)
            id, action = args
            raise Rho::Error, "Use rho memory-review CONVERSATION_ID [status|enable|disable|resume]" if id.to_s.empty?

            workspace = options[:workspace]
            result = case action || "status"
            when "status" then cli.core.memory_review(id, workspace_public_id: workspace)
            when "enable"
              raise Rho::Error, "Choose a memory document with --path, such as user/review.md." if options[:path].to_s.empty?

              cli.core.enable_memory_review(id, path: options[:path], model: options[:model], workspace_public_id: workspace)
            when "disable" then cli.core.disable_memory_review(id, workspace_public_id: workspace)
            when "resume" then cli.core.resume_memory_review(id, workspace_public_id: workspace)
            else raise Rho::Error, "Use status, enable, disable or resume."
            end
            cli.out.puts(options[:json] ? JSON.generate(result) : render(result))
            result
          end

          private

            def render(result)
              return "Memory review is disabled." unless result.fetch("enabled")

              "Memory review is enabled for #{result.fetch("path")}. " \
                "Model: #{result["model"] || "the completed reply's model"}."
            end
        end
      end
    end
  end
end
