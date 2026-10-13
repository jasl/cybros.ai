require "rho/runner"

module Rho
  module AcpClient
    # THE TOOL, built at registration in rho-mcp's
    # `Curation` shape (`Class.new` + `const_set`), closing over the rows
    # and the caller: NAME `delegate_agent` (a working name the bench
    # owns; `delegate` alone names the compaction mode and is refused),
    # DESCRIPTION assembled from the rows' own `description` keys — no
    # stored probe shapes model-facing text — the SCHEMA's
    # `agent` the enabled keys, EFFECT_PROFILE bash's worst case (a foreign
    # agent runs arbitrary commands), TIMEOUT_MS the longest enabled clock
    # (the announced park), INTERNAL_CLAMP (the row's own clock is the
    # wall; the runner never asks the kernel for more on a third party's
    # behalf). The text states the boundary: the child's tools run
    # as the runner's user outside rho's judgement, and the machine
    # boundary is the runner role.
    module Tool
      NAME = "delegate_agent".freeze
      FRAME = "Delegate a task to another coding agent, which works in the runner root with its own tools and its " \
              "own model until it answers. Give the whole task in `prompt`: the agent has none of this " \
              "conversation's context. The result is the agent's reply and a `session` id; pass that `session` to " \
              "continue the same agent with a follow-up. The agent's commands and edits run as this runner's user " \
              "and are refused only where rho's own floor refuses them. Agents:".freeze

      module_function

      # nil when no row is enabled: the extension is then tool-less.
      def build(rows, caller: Rho::AcpClient.method(:call))
        enabled = Array(rows).reject(&:fault?).select(&:enabled?)
        return nil if enabled.empty?

        tool_class(description(enabled), schema(enabled), enabled.map(&:timeout_ms).max, caller)
      end

      # One line per enabled agent, in settings order, after the frame.
      def description(rows)
        enabled = Array(rows).reject(&:fault?).select(&:enabled?)
        lines = enabled.map { |row| "- #{row.key}: #{row.description}" }
        "#{FRAME}\n#{lines.join("\n")}".freeze
      end

      def schema(rows)
        keys = Array(rows).reject(&:fault?).select(&:enabled?).map(&:key)
        Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "agent" => { "type" => "string", "enum" => keys, "description" => "Which agent, by its name above" },
            "prompt" => { "type" => "string", "description" => "The task, in full; the agent starts with nothing else" },
            "session" => { "type" => "string",
                           "description" => "A session id from an earlier delegate_agent result, to continue that agent's session" },
            "workdir" => { "type" => "string",
                           "description" => "Directory the agent works in (absolute, or relative to the runner root). " \
                                            "Defaults to the runner root; fixed for the session's life." },
          },
          "required" => %w[agent prompt],
        })
      end

      # The class closes over the caller alone: the registry builds one
      # instance per toolset and rebuilds them when the root moves.
      def tool_class(description, schema, timeout_ms, caller)
        Class.new do
          const_set(:NAME, Tool::NAME)
          const_set(:DESCRIPTION, description)
          const_set(:SCHEMA, schema)
          const_set(:EFFECT_PROFILE, Rho::Runner::Tools::Bash::EFFECT_PROFILE)
          const_set(:TIMEOUT_MS, timeout_ms)
          const_set(:INTERNAL_CLAMP, true)
          define_singleton_method(:name) { "Rho::AcpClient::Tools[#{Tool::NAME}]" }
          define_singleton_method(:inspect) { name }
          define_method(:initialize) { |env:| @env = env }
          define_method(:call) { |args| caller.call(args, env: @env) }
        end
      end
    end
  end
end
