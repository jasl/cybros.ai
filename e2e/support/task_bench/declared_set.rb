require "cybros_agent"
require_relative "../../../nexus/lib/nexus/tool_registry"
require_relative "../../../nexus/lib/nexus/tool_declarations"
require_relative "../../../nexus/lib/nexus/tool_declarations/render"
require_relative "../adaptation_rows"

module E2E
  module TaskBench
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
          # Every extension whose tool `RunDeclaration.undeclared` hides by name, before the request
          # module that names them: the compaction tool, the process log, and the relay's hidden
          # `environment_bind`.
          require "rho/extensions/compaction"
          require "rho/extensions/processes"
          require "rho/extensions/environment"
          require "rho/run_declaration"
          require "rho/codemode"
          Rho::Runner::Extensions::Loader
            .call(builtin: [Rho::Runner::Extensions::Coding, Rho::Extensions::Processes, Rho::Codemode])
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
      # after. THE HIDDEN NAMES ARE HIDDEN HERE TOO (`Rho::RunDeclaration.undeclared`): the person's
      # relay reads and the runner's `skill` are announced, never declared — the kernel's own
      # `skill` is the one a model calls, and a set carrying both spellings is refused
      # `duplicate_tool_name` at compile.
      def function_definitions(style: "nexus", candidate: nil)
        current_registry = registry
        Rho::RunDeclaration.tool_entries(Rho::RunDeclaration.announcement(registry: current_registry)) + kernel_definitions_for(style, candidate)
      end

      def names(style: "nexus", candidate: nil)
        function_definitions(style: style, candidate: candidate).map { |entry| entry.dig("function", "name") }
      end

      def runner_names = registry.declarations.map { |declaration| declaration.fetch("name") }

      # The STANDALONE seed's system field — the tool lines, a `lead_hints` candidate's lines where
      # a row's hints ride rho's lead, then the guideline (the guideline lives in rho's profile
      # slot; the benchmark supplies it to its standalone request).
      def instructions(candidate: nil) = Rho::RunDeclaration.instructions(registry: registry, hints: candidate&.hint_texts || [])

      # The vendored protocols read symbol keys; the alias facts never reach
      # a provider (`wire`, the kernel's own strip).
      def symbolized_definitions(style: "nexus", candidate: nil)
        Nexus::ToolDeclarations.wire(function_definitions(style: style, candidate: candidate)).map { |entry| symbolize(entry) }
      end

      def symbolize(value) = JSON.parse(JSON.generate(value), symbolize_names: true)
    end
  end
end
