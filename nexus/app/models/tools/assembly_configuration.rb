module Tools
  # Mutable request validation only: these fields are never persisted here.
  # Their grammars are the same validators used by the standing declaration.
  class AssemblyConfiguration
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :tool_definitions
    attribute :kernel_tools
    attribute :runner_executor_public_ids
    attribute :runner_tool_names

    validates :tool_definitions, bounded_json: { bound: :tool_definitions_bound, shape: Array }, allow_nil: true
    # Empty is a deliberate declaration of no explicit tools, while the
    # shared nonempty-entry grammar judges every populated declaration.
    validates :tool_definitions, tool_declarations: true, allow_blank: true
    validates :kernel_tools, :runner_executor_public_ids, :runner_tool_names, tool_imports: true, allow_nil: true

    def to_h
      { tool_definitions: tool_definitions, kernel_tools: kernel_tools,
        runner_executor_public_ids: runner_executor_public_ids, runner_tool_names: runner_tool_names }
    end
  end
end
