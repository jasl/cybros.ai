module Nexus
  # Runner routing is declaration metadata, never model input or a provider schema.
  module ToolRoute
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    FIELDS = %w[kind runner_executor_public_id tool_name].freeze

    module_function

    def refusal(value, declaration: false)
      route = Hash.try_convert(value)
      return "invalid_tool_route" unless route && route["kind"] == "runner"
      allowed = declaration ? FIELDS : FIELDS - ["tool_name"]
      return "invalid_tool_route" if (route.keys - allowed).any?
      if route.key?("runner_executor_public_id")
        id = String.try_convert(route["runner_executor_public_id"])
        return "invalid_tool_route" unless id && UUID.match?(id)
      elsif declaration
        return "runner_target_required"
      end
      return nil unless declaration

      name = String.try_convert(route["tool_name"])
      return "invalid_tool_route" unless name && !name.empty? && name.length <= 128 && !name.include?("\u0000")
      if Nexus::ToolRegistry.kernel_name?(name) &&
          !Nexus::ToolRegistry.routed_by_source?(Nexus::ToolRegistry.resolve(name))
        return "invalid_tool_route"
      end
      nil
    end
  end
end
