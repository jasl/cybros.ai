module Nexus
  # Routing is declaration metadata, never model input or a provider schema.
  module ToolRoute
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    TARGET_FIELDS = { "runner" => "runner_executor_public_id", "mcp" => "connection_public_id" }.freeze

    module_function

    # Accepted UUIDs use PostgreSQL's lowercase spelling in every frozen route.
    def normalize(route)
      target = TARGET_FIELDS.fetch(route.fetch("kind"))
      route.key?(target) ? route.merge(target => route.fetch(target).downcase) : route
    end

    def refusal(value, declaration: false)
      route = Hash.try_convert(value)
      return "invalid_tool_route" unless route
      target_field = TARGET_FIELDS[route["kind"]]
      return "invalid_tool_route" unless target_field

      allowed = ["kind", target_field]
      allowed << "tool_name" if declaration
      return "invalid_tool_route" if (route.keys - allowed).any?
      if route.key?(target_field)
        id = String.try_convert(route[target_field])
        return "invalid_tool_route" unless id && UUID.match?(id)
      elsif declaration || route["kind"] == "mcp"
        return route["kind"] == "runner" ? "runner_target_required" : "mcp_target_required"
      end
      return nil unless declaration

      name = String.try_convert(route["tool_name"])
      return "invalid_tool_route" unless name && !name.empty? && name.length <= 128 && !name.include?("\u0000")
      if route["kind"] == "runner" && Nexus::ToolRegistry.kernel_name?(name) &&
          !Nexus::ToolRegistry.routed_by_source?(Nexus::ToolRegistry.resolve(name))
        return "invalid_tool_route"
      end
      nil
    end
  end
end
