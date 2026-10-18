module Rho
  module Codemode
    class Code
      NAME = "code".freeze
      BINDING_ID = "urn:cybros:rho:codemode:javascript:1".freeze
      DESCRIPTION = Authoring::INSTRUCTIONS
      SCHEMA = {
        "$id" => BINDING_ID,
        "type" => "object",
        "properties" => {
          "code" => { "type" => "string", "description" => "JavaScript async function body." },
          "params" => { "description" => "Immutable JSON parameters available as params." },
        },
        "required" => ["code"],
        "additionalProperties" => false,
      }.freeze
      # External effects belong to accepted child tasks; the interpreter itself
      # has no ambient IO. Losing its live state does not re-execute the source.
      EFFECT_PROFILE = {
        "kind" => "pure", "destructive" => false, "effect_scope" => "closed",
        "idempotency" => "intrinsic", "reconciliation" => "none",
      }.freeze
      PROMPT_SNIPPET = "Run async JavaScript over declared tools and select final output.".freeze

      def initialize(env:)
        @runtime = Runtime.new
      end

      def call(args)
        context = Rho::Runner::ExecutionContext.current
        unless context&.orchestration
          raise ArgumentError, "code requires a claim-scoped task orchestration bridge"
        end

        context.orchestration.run(
          program: { "source" => args.fetch("code"), "params" => args.fetch("params", {}) },
          runtime: @runtime
        )
      end
    end
  end
end
