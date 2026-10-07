module Nexus
  # The import intent shared by Profile declarations and authored model work.
  # Nil and an empty list import no plain kernel tools or Runner candidates;
  # runner_tool_names alone distinguishes nil (all model tools) from [] (none).
  module ToolImports
    FIELDS = %i[kernel_tools runner_executor_public_ids runner_tool_names].freeze
    Refusal = Data.define(:field, :code)

    module_function

    def refusal(kernel_tools:, runner_executor_public_ids:, runner_tool_names:)
      values = { kernel_tools: kernel_tools, runner_executor_public_ids: runner_executor_public_ids,
        runner_tool_names: runner_tool_names }
      values.each do |field, value|
        code = field_refusal(field: field, value: value)
        return Refusal.new(field: field, code: code) if code
      end
      nil
    end

    def field_refusal(field:, value:)
      return nil if value.nil?

      entries = Array.try_convert(value)
      return :invalid unless entries && entries.uniq == entries
      valid = case field
      when :kernel_tools
        (entries - ToolRegistry.live_names).empty?
      when :runner_executor_public_ids
        ids = entries.map { |value| String.try_convert(value)&.downcase }
        ids.uniq == ids && ids.all? { |id| id && ToolRoute::UUID.match?(id) }
      when :runner_tool_names
        entries.all? { |name| tool_name?(name) }
      else
        raise ArgumentError, "unknown tool import field: #{field}"
      end
      return :invalid unless valid

      SizeBounds::REJECTION unless SizeBounds.json_within?(:tool_definitions_bound, entries)
    end

    def tool_name?(value)
      name = String.try_convert(value)
      name && !name.empty? && name.length <= 128 && !name.include?("\u0000")
    end
    private_class_method :tool_name?
  end
end
