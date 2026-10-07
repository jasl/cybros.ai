require "rho/runner"

module Rho
  module Extensions
    # THE DELEGATE SUMMARIZER: the kernel compacts by default, and an agent that
    # declares its own receives each compaction as an inbox row addressed
    # to its own address — a `tool_call` naming the profile's policy
    # `tool_name`, carrying the history and the retained tail — and answers
    # it with the summary. This is rho's own: one InferenceRequest on the member
    # plane, on the model the settings name, under rho's own prompt, the
    # text committed as the row's answer.
    #
    # A SHIPPED EXTENSION, not a core file, because a TOOL registers from an
    # extension and a shipped default extension is
    # how core behaviour takes that shape (`Ops` is the precedent). It is
    # ANNOUNCED whenever it loads — the kernel addresses the delegate only
    # to an address that announced the name — while DECLARING the policy
    # is the settings flag's alone (`compaction: {mode: delegate}`); the
    # kernel's summarizer stays the shipped default. The name is never
    # offered to a model: `RunDeclaration.tool_entries` leaves it out of the
    # declaration, so it is addressed by policy, never by a call.
    #
    # The member plane reaches the tool as a CALLABLE bound at registration
    # (`Extensions::Host#member_plane`): the daemon's Context is born after
    # the extensions register, so it is dereferenced when the tool runs.
    # Nil-safe under a loader with no daemon — the tool answers an error.
    module Compaction
      NAME = "rho.compaction".freeze
      TOOL_NAME = "summarize_history".freeze

      # RHO'S OWN PROMPT — the whole point of a delegate is the agent's own
      # text, not the kernel's `Summarizer::INSTRUCTIONS`. Pinned byte for
      # byte (`test/extensions/compaction_test.rb`): the coding-agent
      # sections, the re-read-as-pointers rule against fabricated values,
      # "write only the summary".
      INSTRUCTIONS = <<~TEXT.strip.freeze
        You are summarizing the earlier part of a coding agent's conversation so the agent can continue with less context. The history below is what happened; the retained tail is what the agent will still see verbatim after your summary.

        Write the summary under these headings, each as short as the facts allow:
        - Goal: what the person asked for, in their words where it matters.
        - Done: the changes made, by file and function, and the commands run with their results.
        - Findings: the facts established (versions, paths, behaviours, failing tests) that later steps depend on.
        - Open: what is not finished, decisions still pending, and the person's standing instructions.

        Rules:
        - Tool results were cut to their head and may be incomplete: do not invent values, counts, paths or outputs that are not in the text. Name the file or command to re-read instead ("re-run the tests to see the failing names").
        - Keep exact identifiers verbatim: file paths, function names, error messages, commit hashes, task keys.
        - Write only the summary. No preamble, no closing remark, no advice to the reader.
      TEXT

      # A summarizer that could not run: raised out of the handler so the
      # task run answers `outcome: failed` — a FAILED row under the
      # policy's absorb, never a `completed, is_error` text a composer
      # might read as history (belt and braces with the kernel's own
      # `arrived_summary` guard).
      class NoSummary < Rho::Error; end

      def self.policy(config, active:)
        return { "mode" => "off" } unless active

        values = config.plugin_configuration(NAME)
        if values.fetch("mode") == "delegate"
          { "mode" => "delegate", "tool_name" => TOOL_NAME }
        else
          { "mode" => "kernel", "model" => values["model"] }.compact
        end
      end

      def self.register(api)
        model = api.configuration["model"] || api.host.config.default_model
        if api.configuration.fetch("mode") == "delegate" && model.nil?
          api.describe_status { { ready: false, issues: ["Select a compaction model or a default model"] } }
          return
        end
        tool = Class.new(SummarizeHistory)
        (Rho::Runner::Extensions::Tool::REQUIRED_CONSTANTS + [:TIMEOUT_MS]).each do |name|
          tool.const_set(name, SummarizeHistory.const_get(name))
        end
        tool.bind(member_plane: api.host&.member_plane, model: model)
        # The agent's own tool: announced on the agent-application
        # address, never on the runner's.
        api.register_tool(tool, serves: :agent)
      end
    end
  end
end

require_relative "compaction/summarize_history"
