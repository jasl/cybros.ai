require_relative "preset_execution"
require_relative "bot_policy"

module Rho
  # A role publishes selection metadata for a Preset. This compiler captures its
  # resolved configuration alongside the caller's declaration, without creating
  # another principal or inheriting the caller's narrower tool selection.
  module RoleDeclarations
    SPAWN = "nexus.conversation.spawn".freeze
    CHILD_MEMORY = { "bindings" => [
      { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
    ] }.freeze

    module_function

    def compile(preset:, presets:, base:, wire_names:, audience: "owner", send_targets: [])
      published = presets.select(&:role)
      roles = published.map { |entry| entry.role.to_h.transform_keys(&:to_s) }
      declaration = resolve(preset, base, roles, wire_names, audience, send_targets)
      catalog = published.map do |entry|
        child = resolve(entry, base, roles, wire_names, audience, send_targets)
        child[:memory_context_limit] = PresetExecution.limit_memory(child[:memory_context_limit], ceiling: CHILD_MEMORY)
        child[:conversation_reach] = "subtree"
        template = child[:prompt_template] || RunDeclaration::PROMPT_TEMPLATE
        child[:prompt_template] = template.merge("blocks" => template.fetch("blocks").reject do |block|
          block["type"] == "slot" && block["slot"] == "persona"
        end)
        child[:prompt_mechanism] = "assembly"
        { "name" => entry.role.name, "description" => entry.role.description,
          "model_mode" => entry.configuration.fetch("model_mode") == "follow" ? "caller" : "default",
          "declaration" => child.transform_keys(&:to_s) }
      end
      declaration.merge(delegation_catalog: catalog)
    end

    def resolve(preset, base, roles, wire_names, audience, send_targets)
      declaration = PresetExecution.declaration(preset: preset, base: base, kernel_tool_names: wire_names)
      declaration = with_roles(declaration, roles, wire_names)
      if audience == "external"
        declaration = BotPolicy.external(declaration, send_targets: send_targets, spawn_roles: roles, wire_names: wire_names)
      end
      declaration
    end

    def with_roles(declaration, roles, wire_names)
      aliases = declaration.fetch(:tool_definitions).map do |entry|
        entry["canonical"] == SPAWN ? spawn_alias(entry, roles) : entry
      end
      if declaration.fetch(:kernel_tools).include?(SPAWN)
        aliases << spawn_alias(CybrosAgent::Api::ToolCatalog.new(dispatch: nil).alias(
          name: wire_names.fetch(SPAWN), canonical: SPAWN), roles)
      end
      prompt = declaration.fetch(:system_prompt)
      declaration.merge(kernel_tools: declaration.fetch(:kernel_tools) - [SPAWN], tool_definitions: aliases,
        system_prompt: prompt.merge("content" => [prompt.fetch("content"), guidance(roles)].join("\n\n")))
    end

    def spawn_alias(entry, roles)
      params = entry.fetch("params", {})
      name = params.find { |_key, value| value["maps_to"] == "declaration" }&.first ||
        params.find { |_key, value| value["maps_to"] == "agent" }&.first || "role"
      params = params.reject { |key, value| key != name && %w[agent declaration].include?(value["maps_to"]) }
      description = "Required. Select one published Subagent role by its exact name.\n" +
        roles.map { |role| "- #{role.fetch("name")}: #{role.fetch("description")}" }.join("\n")
      entry.merge("params" => params.merge(name => { "maps_to" => "declaration", "description" => description }),
        "omit" => (entry.fetch("omit", []) - ["declaration"] + ["agent"]).uniq)
    end

    def guidance(roles)
      return "No Subagent roles are published for this execution. Do not spawn a Bot identity as a substitute." if roles.empty?

      <<~TEXT.strip
        Available Subagent roles:
        #{roles.map { |role| "- #{role.fetch("name")}: #{role.fetch("description")}" }.join("\n")}

        Select the exact role when delegating. For ordinary delegated work, choose worker when available. Each child starts with an explicit task brief and its own conversation memory; it does not automatically receive your transcript or the owner's private notes. Include the goal, relevant context, constraints, expected result and verification criteria. Parallel file changes need disjoint ownership. A later review is a separate delegation after the implementation result is available; pass the relevant artifacts and evidence to the reviewer.

        A role follows your current model or uses its configured default. A model requested for one delegation overrides that role for that task without editing its Preset. Resolve user-supplied model names against the available model catalog through tool discovery, use an exact provider/model reference, and ask if the name is ambiguous. Never guess a reference. Preserve the person's model and provider restrictions; include any expressly permitted alternatives in model_selection. Each role carries its own captured fallback list.
      TEXT
    end
  end
end
