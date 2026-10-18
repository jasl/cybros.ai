require_relative "run_declaration"
require_relative "code_mode"
require_relative "preset_execution/memory"
require_relative "preset_execution/mcp"

module Rho
  # External prompts may choose work only inside the Bot's declared surface.
  # The kernel enforces these existing rules and scope limits when it captures
  # execution. Ordinary private Runner and custom callables stay excluded; MCP
  # follows the same explicit selection as owner conversations.
  module BotPolicy
    KERNEL_TOOLS = %w[
      nexus.memory.read nexus.memory.write nexus.memory.edit nexus.memory.ls nexus.memory.grep nexus.memory.delete
      nexus.skill.load nexus.tools.search nexus.tools.call nexus.models.list nexus.human.ask nexus.graph.delegate_task nexus.graph.wait
      nexus.conversation.spawn nexus.conversation.send nexus.conversation.status nexus.conversation.cancel
      nexus.conversation.search nexus.conversation.read
    ].freeze
    SUBAGENT_TOOLS = %w[nexus.conversation.spawn nexus.graph.delegate_task].freeze
    DELEGATION_TOOLS = %w[nexus.conversation.spawn nexus.conversation.send].freeze
    MEMORY_CONTEXT_LIMIT = { "bindings" => [
      { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
      { "name" => "speaker", "scope" => "speaker", "access" => "read_write" },
      { "name" => "workspace", "scope" => "workspace", "access" => "read" },
    ] }.freeze

    class << self
      # Product modes narrow only the Bot root. Published worker declarations
      # and existing approval rules keep their independently compiled policy.
      def conversation(configuration, subagent:, runner_names:)
        tools = CodeMode.tools(configuration.fetch(:tool_definitions), false)
        tools = tools.reject { |entry| SUBAGENT_TOOLS.include?(entry["canonical"]) } unless subagent
        kernels = configuration.fetch(:kernel_tools)
        kernels -= SUBAGENT_TOOLS unless subagent
        prompt = configuration.fetch(:system_prompt)
        policy = "This is a Bot main conversation. Code Mode is off: do not use the code tool; use the available ordinary tools."
        unless subagent
          policy += " Subagent is off: carry out the person's work directly in this conversation. Do not spawn or delegate work to another agent. Wait for the work to finish before reporting its result; do not finish with a launch acknowledgement."
        end
        configuration.merge(tool_definitions: tools, kernel_tools: kernels,
          runner_tool_names: (configuration.fetch(:runner_tool_names) || runner_names) - ["code"],
          system_prompt: prompt.merge("content" => [prompt.fetch("content"), policy].join("\n\n")))
      end

      def external(configuration, send_targets:, spawn_roles:, wire_names:, mcp_names: [])
        kernels = configuration.fetch(:kernel_tools) & KERNEL_TOOLS
        aliases = configuration.fetch(:tool_definitions).select { |entry| KERNEL_TOOLS.include?(entry["canonical"]) }
        aliases = aliases.map { |entry| with_destinations(entry, send_targets, spawn_roles) }
        (kernels & DELEGATION_TOOLS).each do |canonical|
          aliases << with_destinations(CybrosAgent::Api::ToolCatalog.new(dispatch: nil).alias(
            name: wire_names.fetch(canonical), canonical: canonical), send_targets, spawn_roles)
        end
        declared = (kernels + aliases.map { |entry| entry.fetch("canonical") }).uniq
        mcp_definitions = configuration.fetch(:tool_definitions).select { |entry| mcp_names.include?(entry.dig("function", "name")) }
        mcp_rules = mcp_approval_rules(configuration, mcp_names)
        template = configuration[:prompt_template] || RunDeclaration::PROMPT_TEMPLATE
        restrictions = configuration.fetch(:approval_rules).select { |rule| %w[deny ask].include?(rule.fetch("verdict")) }
        configuration.merge(
          kernel_tools: kernels - DELEGATION_TOOLS, tool_definitions: aliases + mcp_definitions,
          runner_executor_public_ids: [], runner_tool_names: [], approval_mode: "rules",
          approval_rules: restrictions + mcp_rules + approval_rules(declared, send_targets, spawn_roles, wire_names),
          prompt_mechanism: "assembly",
          prompt_template: template.merge("blocks" => template.fetch("blocks").reject { |block| block["type"] == "slot" && block["slot"] == "persona" }),
          memory_context_limit: PresetExecution.limit_memory(configuration[:memory_context_limit], ceiling: MEMORY_CONTEXT_LIMIT),
          conversation_reach: "subtree"
        )
      end

      private

        # Preserve the selected MCP posture while narrowing authored allow
        # patterns to exact MCP callables. They cannot widen Bot send/spawn.
        def mcp_approval_rules(configuration, names)
          return [] if names.empty?

          mode = configuration.fetch(:approval_mode)
          return [{ "tool" => names.join("|"), "verdict" => mode == "ask" ? "ask" : "allow" }] unless mode == "rules"

          aliases = configuration.fetch(:tool_definitions).filter_map do |entry|
            name = entry.dig("function", "name")
            served = entry.dig("route", "tool_name")
            [served, name] if served && names.include?(name)
          end
          configuration.fetch(:approval_rules).filter_map do |rule|
            next unless rule.fetch("verdict") == "allow"

            selected = PresetExecution::Mcp.matching_names(rule.fetch("tool"), names)
            served = PresetExecution::Mcp.matching_names(rule.fetch("tool"), aliases.map(&:first))
            selected = (selected + aliases.filter_map { |original, name| name if served.include?(original) }).uniq
            rule.merge("tool" => selected.join("|")) unless selected.empty?
          end
        end

        def with_destinations(entry, send_targets, spawn_roles)
          case entry.fetch("canonical")
          when "nexus.conversation.send"
            lines = send_targets.map { |row| "- #{row.public_id} (@#{row.handle}): #{row.description}" }
            description = "Required. Pass one exact Bot UUID below; do not omit this argument or use an @handle.\n#{lines.join("\n") }"
            with_selector(entry, "agent", description)
          when "nexus.conversation.spawn"
            lines = spawn_roles.map { |role| "- #{role.fetch("name")}: #{role.fetch("description")}" }
            description = "Required. Choose one exact Subagent role below for this task.\n#{lines.join("\n") }"
            with_selector(entry, "declaration", description, omit: ["agent"])
          else entry
          end
        end

        def with_selector(entry, field, description, omit: [])
          params = entry.fetch("params", {}).reject { |name, specification| omit.include?(specification.fetch("maps_to", name)) }
          name = params.find { |_key, specification| specification["maps_to"] == field }&.first || field
          entry.merge("params" => params.merge(name => { "maps_to" => field, "description" => description }),
            "omit" => (entry.fetch("omit", []) + omit).uniq - [field])
        end

        def approval_rules(declared, send_targets, spawn_roles, wire_names)
          ordinary = (declared - DELEGATION_TOOLS).map { |canonical| wire_names.fetch(canonical) }
          rules = ordinary.empty? ? [] : [{ "tool" => ordinary.join("|"), "verdict" => "allow" }]
          if declared.include?("nexus.conversation.send")
            rules.concat(send_targets.map do |row|
              { "tool" => wire_names.fetch("nexus.conversation.send"), "path" => "agent", "match" => row.public_id, "verdict" => "allow" }
            end)
          end
          if declared.include?("nexus.conversation.spawn")
            rules.concat(spawn_roles.map do |role|
              { "tool" => wire_names.fetch("nexus.conversation.spawn"), "path" => "declaration", "match" => role.fetch("name"), "verdict" => "allow" }
            end)
          end
          rules
        end
    end
  end
end
