module Rho
  module Extensions
    # Rho supplies summary policy and text; Nexus executes compression.
    module Compaction
      NAME = "rho.compaction".freeze

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

      def self.policy(config, active:)
        return { "mode" => "off" } unless active

        { "mode" => "kernel", "model" => config.plugin_configuration(NAME)["model"] }.compact
      end

      def self.register(_api); end
    end
  end
end
