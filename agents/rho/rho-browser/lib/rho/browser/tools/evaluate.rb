require "json"
require_relative "base"

module Rho
  module Browser
    module Tools
      # THE ONE ESCAPE HATCH, declared as what it is. Every fine-grained
      # browser surface in the references keeps exactly one of these —
      # `browser_evaluate`, `javascript_tool`, `browser_cdp` — because the
      # alternative is a single `code` tool where every action is opaque
      # and approval has to leave the tool boundary for an LLM reviewer.
      # Five narrow tools keep five honest effect profiles; this one keeps
      # the dangerous one, and says so.
      class Evaluate
        include Base

        NAME = "browser_evaluate".freeze
        EFFECT_PROFILE = ACTS_ON_PAGE
        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "expression" => {
              "type" => "string",
              "description" => "JavaScript evaluated in the page; its value is returned as JSON",
            },
          },
          "required" => ["expression"],
        })
        DESCRIPTION =
          "Run JavaScript in the page and return its value as JSON. This can do anything the " \
          "page can; use the other browser tools when they can express the action.".freeze
        PROMPT_SNIPPET = "Run JavaScript in the page (escape hatch)".freeze
        PROMPT_GUIDELINES = GUIDELINES

        MAX_BYTES = Rho::Runner::Truncation::DEFAULT_MAX_BYTES

        def call(args)
          missing = required(args, "expression")
          return missing if missing

          expression = args["expression"].to_s
          on_page do |page, fresh|
            value = page.evaluate(expression)
            Rho::Runner::Result.ok(noticed(SnapshotText.clamp(JSON.generate(finite(value)), MAX_BYTES), fresh))
          end
        end

        private

          # JSON HAS NO NaN. The page can answer one — `0/0`, a width read
          # off a detached node — and the gem hands it over as Float::NAN,
          # which the generator refuses. The model asked for a value and
          # gets `null` for the ones JSON cannot carry, not an error about
          # the format it never chose.
          # AND NO CYCLES. A page can answer `window` or a React node whose
          # fiber graph points back at itself; the gem rebuilds that as a
          # real Ruby cycle, and a plain walk over it is a SystemStackError
          # — not a StandardError, so it would fail the task instead of
          # answering the model. Seen objects are marked, and depth is
          # capped for the graphs that are merely absurd.
          MAX_DEPTH = 64

          def finite(value, seen = {}.compare_by_identity, depth = 0)
            case value
            when Float then value.finite? ? value : nil
            when Hash, Array
              return "[circular]" if seen[value]
              return "[too deep]" if depth >= MAX_DEPTH

              seen[value] = true
              walked =
                if value.is_a?(Hash)
                  value.to_h { |k, v| [k, finite(v, seen, depth + 1)] }
                else
                  value.map { |v| finite(v, seen, depth + 1) }
                end
              seen.delete(value)
              walked
            else value
            end
          end
      end
    end
  end
end
