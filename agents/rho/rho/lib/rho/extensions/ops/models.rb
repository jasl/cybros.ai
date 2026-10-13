module Rho
  module Extensions
    module Ops
      # Discovery uses the daemon's member plane. Lane and credential
      # management remain on the platform's operator plane.
      module Models
        def self.register(api)
          api.register_route("GET", "/models") { |request, ctx| list(request, ctx) }
          api.register_command("models",
            description: "List the models the account can currently use",
            options: {
              workload: { type: :string, desc: "Filter by workload, such as text_generation" },
              json: { type: :boolean, default: false, desc: "Print the available models as JSON" },
            }, &method(:command))
        end

        def self.list(request, ctx)
          query = ControlServer.query(request)
          ctx.member_plane(require_workspace: false) do |client|
            rows = client.models.list(workload: query["workload"])
            [200, { models: rows.map { |row| row.to_h.merge(pricing: row.pricing.to_h) } }]
          end
        end

        def self.command(cli, _args, options)
          rows = cli.core.models(workload: options[:workload])
          if options[:json]
            cli.out.puts JSON.generate(models: rows)
          elsif rows.empty?
            cli.out.puts "(no models)"
          else
            rows.each do |row|
              cli.out.puts "#{row.fetch("ref")}  #{row.fetch("workload")}"
            end
          end
          rows
        end
      end
    end
  end
end
