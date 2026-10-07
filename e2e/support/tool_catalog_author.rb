# A diagnostic client inside the paired rho process. Both reads and writes use
# the ordinary member API; diagnostic controls can replace tools and prompt slots.
module ToolCatalogAuthor
  NAME = "e2e.tool-catalog-author".freeze

  def self.register(api)
    api.register_route("GET", "/e2e/tool-catalog") do |request, ctx|
      ctx.member_plane(request) do |client, *|
        [200, { "configuration" => client.profile.fetch.configuration.to_h,
          "prompt_documents" => prompt_documents(client) }]
      end
    end
    api.register_route("POST", "/e2e/tool-assembly") do |request, ctx|
      ctx.member_plane(request, body: true) do |client, _workspace, _about, body|
        assembled = client.tools.assemble(
          default_runner_executor_public_id: body.fetch("default_runner_executor_public_id"),
          configuration: body["configuration"]
        )
        [200, assembled.to_h]
      end
    end
    api.register_route("POST", "/e2e/tool-catalog") do |request, ctx|
      ctx.member_plane(request, body: true) do |client, _workspace, _about, body|
        configuration = client.profile.fetch.configuration.to_h.transform_keys(&:to_sym)
        configuration[:tool_definitions] = body.fetch("tool_definitions")
        %w[kernel_tools runner_executor_public_ids runner_tool_names].each do |field|
          configuration[field.to_sym] = body.fetch(field) if body.key?(field)
        end
        documents = body.fetch("prompt_documents") { prompt_documents(client) }
        profile = client.profile.declare_configuration(**configuration, prompt_documents: documents)
        [200, { "configuration" => profile.configuration.to_h }]
      end
    end
  end

  def self.prompt_documents(client)
    client.profile.prompt_documents.list.to_h do |row|
      document = client.profile.prompt_documents.read(row.slot)
      [row.slot, { "content" => document.content, "role" => document.role }]
    end
  end
end
