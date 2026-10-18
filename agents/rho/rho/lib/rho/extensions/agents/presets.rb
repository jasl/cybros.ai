require_relative "../../agent_presets/portable"

module Rho
  module Extensions
    module Agents
      # Configuration authoring never calls the kernel's identity-creation API.
      module Presets
        module_function

        def register(api)
          api.register_route("GET", "/presets") { |_request, ctx| list(ctx) }
          api.register_route("GET", "/presets/tools") { |request, ctx| tools(request, ctx) }
          %w[POST PUT].each do |method|
            api.register_route(method, "/presets") { |request, ctx| write(request, ctx, create: method == "POST") }
          end
          api.register_route("POST", "/presets/duplicate") { |request, ctx| change(request, ctx) { |catalog, body| catalog.duplicate(body.fetch("public_id"), name: body.fetch("name")) } }
          api.register_route("POST", "/presets/rm") { |request, ctx| remove(request, ctx) }
          api.register_route("GET", "/presets/export") { |request, ctx| export(request, ctx) }
          api.register_route("POST", "/presets/import_document") { |request, ctx| import_document(request, ctx) }
          api.register_route("POST", "/presets/import") { |request, ctx| import_files(request, ctx) }
          api.register_route("PUT", "/presets/defaults") { |request, ctx| defaults(request, ctx) }
          api.register_route("PUT", "/presets/role") do |request, ctx|
            change(request, ctx) { |catalog, body| catalog.publish(body.fetch("public_id"), name: body.fetch("name"), description: body.fetch("description")) }
          end
          api.register_route("DELETE", "/presets/role") { |request, ctx| change(request, ctx) { |catalog, body| catalog.unpublish(body.fetch("public_id")) } }
        end

        def tools(_request, ctx)
          answer = ctx.list_preset_tools
          (answer in Daemon::Refusal) ? answer : [200, answer]
        end

        def list(ctx)
          ctx.agent_presets { |catalog| [200, listing(catalog)] }
        end

        def write(request, ctx, create:)
          change(request, ctx) do |catalog, body|
            fields = { name: body.fetch("name"), description: body.fetch("description"), configuration: body.fetch("configuration", {}) }
            create ? catalog.create(**fields) : catalog.replace(body.fetch("public_id"), **fields)
          end
        end

        def remove(request, ctx)
          change(request, ctx) do |catalog, body, client|
            id = body.fetch("public_id")
            used = client.profile.agents.list.find do |row|
              row.derived_from_public_id == ctx.own_user_public_id &&
                BotSettings.new(store: -> { client.profile.store_entries }, agent_public_id: row.public_id).read.preset_public_id == id
            end
            raise AgentPresets::Error, "Preset is in use by Bot #{used.display_name || used.name}" if used

            catalog.remove(id)
          end
        end

        def export(request, ctx)
          query = ControlServer.query(request)
          ctx.agent_presets do |catalog|
            entry = catalog.fetch(query.fetch("public_id"))
            format = query.fetch("format", "md")
            [200, { name: entry.name, format: format, content: AgentPresets::Portable.dump(entry, format: format) }]
          end
        rescue KeyError => error
          Daemon::Refusal.parameter_missing(error.key)
        end

        def import_document(request, ctx)
          change(request, ctx) do |catalog, body|
            fields = AgentPresets::Portable.load(body.fetch("content"), format: body.fetch("format"), filename: body.fetch("filename", "preset.md"))
            fields[:name] = body.fetch("name") if body.key?("name")
            catalog.create(**fields)
          end
        end

        def import_files(request, ctx)
          body = ControlServer.json_body(request)
          names = body["names"]
          if !names.nil? && Array.try_convert(names).nil?
            return Daemon::Refusal.malformed("names must be a list of Preset names")
          end
          ctx.agent_presets do |catalog|
            root = ctx.environment.root
            imported = []
            skipped = []
            seen = []
            paths = root ? AgentPresets::Portable::DIRECTORIES.flat_map { |directory| Dir.glob(File.join(root, directory, "*.{md,json}")).sort } : []
            paths.each do |path|
              begin
                fields = AgentPresets::Portable.load(File.read(path, encoding: "UTF-8"), format: File.extname(path).delete_prefix("."), filename: path)
                name = fields.fetch(:name)
                next if names && !names.include?(name)
                next if seen.include?(name)

                imported << catalog.create(**fields).to_h
                seen << name
              rescue AgentPresets::Error, SystemCallError, EncodingError => error
                skipped << { path: path, reason: error.message }
              end
            end
            [200, listing(catalog).merge(imported: imported, skipped: skipped, missing: names ? names - seen : [])]
          end
        end

        def defaults(request, ctx)
          change(request, ctx) do |catalog, body|
            keys = body.keys - %w[main_preset_public_id default_bot_preset_public_id]
            raise AgentPresets::Error, "Unknown default selection fields: #{keys.join(", ")}" unless keys.empty?

            catalog.select_defaults(body)
          end
        end

        def change(request, ctx)
          body = ControlServer.json_body(request)
          ctx.agent_presets do |catalog, client|
            yield catalog, body, client
            [200, listing(catalog)]
          end
        rescue KeyError => error
          Daemon::Refusal.malformed("Required Preset field is missing: #{error.key}")
        end

        def listing(catalog)
          { presets: catalog.list.map(&:to_h), main_preset_public_id: catalog.main_preset_public_id,
            default_bot_preset_public_id: catalog.default_bot_preset_public_id }
        end
      end
    end
  end
end
