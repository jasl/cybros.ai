require "json_schemer"

module Rho
  # Reopened by `rho/runner.rb`, which holds the loop itself.
  class Runner
    # ARGUMENTS ARE VALIDATED AGAINST THE DECLARED `inputSchema` BEFORE THE
    # HANDLER RUNS, and a mismatch is DATA — `Result.error`
    # submits as `completed, is_error: true`, so the model reads which field
    # was wrong and corrects itself, where a handler raising on a bad
    # argument took the round's failure policy and told it nothing
    # (opencode validates against the declared schema the same way).
    #
    # json_schemer, not a hand validator: the schemas are MCP `inputSchema`
    # — JSON Schema as it is written in the wild — and a subset of a
    # standard is a second implementation of it.
    module InputSchema
      # The first few errors are the readable ones; a model corrects one
      # field at a time and the text is bounded like every other result.
      MAX_ERRORS = 3
      MAX_BYTES = 512

      module_function

      # ONE COMPILE PER TOOL, at load: a schema the validator itself refuses
      # (`required` given as a string, say) is refused where somebody can
      # still read it, never at the first call as the validator's own
      # exception.
      def compile(schema)
        problems = JSONSchemer.validate_schema(schema).first(MAX_ERRORS).map { |error| error["error"] }
        raise ArgumentError, "a SCHEMA json_schemer cannot compile: #{problems.join("; ")}" unless problems.empty?

        JSONSchemer.schema(schema)
      end

      # nil when the arguments fit; otherwise the sentence the model reads.
      def refusal(validator, arguments)
        errors = validator.validate(arguments).first(MAX_ERRORS)
        return nil if errors.empty?

        bounded(errors.map { |error| error["error"] }.join("; "))
      end

      # The HEAD is kept — the first error is the one to fix first.
      def bounded(text)
        return text if text.bytesize <= MAX_BYTES

        "#{text.byteslice(0, MAX_BYTES - "…".bytesize).scrub("")}…"
      end
    end
  end
end
