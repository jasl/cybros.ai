require "cybros_agent"
require_relative "../../../nexus/lib/nexus/tool_registry"
require_relative "../../../nexus/lib/nexus/tool_declarations"
require_relative "../../../nexus/lib/nexus/tool_declarations/render"
require_relative "../adaptation_rows"

module E2E
  module TaskBench
    # THE SET A RHO TURN DECLARES, assembled the way rho assembles it: the runner's coding tools
    # plus the daemon's processes extension, lowered through the SDK to function entries, then the
    # kernel's live tools (`compose`, `task`, `ask`, the memory verbs) — and rho's own instructions
    # block, guideline included, as the system text. A probe that declared a hand-written subset
    # would measure the subset. Under a STYLE the kernel's entries pass through the SDK pack's alias
    # tables (`CybrosAgent::ModelAdaptations`, a harness-built row per style id — a plain name only
    # with `nexus` or while no active preset supersedes it, each preset's aliases added, a recut
    # rendered against the kernel's own template) and the kernel's render — the stored form a rho
    # profile holds: `AdaptationRows. style_row` and `kernel_entries_under`, the compose bench's
    # same two calls.
    module DeclaredSet
      RHO_RUNNER_LIB = File.expand_path("../../../agents/rho/rho-runner/lib", __dir__)
      RHO_LIB = File.expand_path("../../../agents/rho/rho/lib", __dir__)

      module_function

      def registry
        @registry ||= begin
          $LOAD_PATH.unshift(RHO_RUNNER_LIB) unless $LOAD_PATH.include?(RHO_RUNNER_LIB)
          $LOAD_PATH.unshift(RHO_LIB) unless $LOAD_PATH.include?(RHO_LIB)
          require "rho/runner"
          require "rho/errors"
          # Every extension whose tool `LoopRequest.undeclared` hides by name, before the request
          # module that names them: the compaction tool, the process log, and the relay's hidden
          # `environment_bind`.
          require "rho/extensions/compaction"
          require "rho/extensions/processes"
          require "rho/extensions/environment"
          require "rho/loop_request"
          Rho::Runner::Extensions::Loader
            .call(builtin: [Rho::Runner::Extensions::Coding, Rho::Extensions::Processes])
            .registry
        end
      end

      # The kernel's entries under a style, rendered by the kernel: every
      # live tool under the style's harness row; a `tool_descriptions`
      # candidate's entry rides the row as its own description variant.
      def kernel_definitions_for(style, candidate = nil)
        row = AdaptationRows.style_row(style, AdaptationRows.words(style), tool_descriptions: candidate&.entries || [])
        AdaptationRows.kernel_entries_under(row)
      end

      # String-keyed, sorted by name on the runner half exactly as rho sends them, the kernel's
      # after. THE HIDDEN NAMES ARE HIDDEN HERE TOO (`Rho::LoopRequest.undeclared`): the person's
      # relay reads and the runner's `skill` are announced, never declared — the kernel's own
      # `skill` is the one a model calls, and a set carrying both spellings is refused
      # `duplicate_tool_name` at compile.
      def function_definitions(style: "nexus", candidate: nil)
        CybrosAgent::Api::ToolLowering.function_entries(offered_declarations) + kernel_definitions_for(style, candidate)
      end

      def offered_declarations
        # `registry` loads rho's lib (`Rho::LoopRequest` with it): resolve it
        # BEFORE the constant is looked up.
        declarations = registry.declarations
        hidden = Rho::LoopRequest.undeclared
        declarations.reject { |declaration| hidden.include?(declaration.fetch("name")) }
      end

      def names(style: "nexus", candidate: nil)
        function_definitions(style: style, candidate: candidate).map { |entry| entry.dig("function", "name") }
      end

      # A branch drops the graph verbs under whatever spelling: by canonical.
      def branch_names(style: "nexus")
        function_definitions(style: style)
          .reject { |entry| %w[nexus.graph.task nexus.graph.compose].include?(Nexus::ToolDeclarations.canonical_of(entry)) }
          .map { |entry| entry.dig("function", "name") }
      end

      def runner_names = registry.declarations.map { |declaration| declaration.fetch("name") }

      # The STANDALONE seed's system field — the tool lines, a `lead_hints` candidate's lines where
      # a row's hints ride rho's lead, then the guideline (the guideline lives in rho's profile
      # slot; the benchmark supplies it to its standalone request).
      def instructions(candidate: nil) = Rho::LoopRequest.instructions(registry: registry, hints: candidate&.hint_texts || [])

      # The vendored protocols read symbol keys; the alias facts never reach
      # a provider (`wire`, the kernel's own strip).
      def symbolized_definitions(style: "nexus", candidate: nil)
        Nexus::ToolDeclarations.wire(function_definitions(style: style, candidate: candidate)).map { |entry| symbolize(entry) }
      end

      def symbolize(value)
        case value
        when Hash then value.to_h { |key, inner| [key.to_sym, symbolize(inner)] }
        when Array then value.map { |inner| symbolize(inner) }
        else value
        end
      end
    end
  end
end
