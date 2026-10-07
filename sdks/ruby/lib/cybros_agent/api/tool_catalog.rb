module CybrosAgent
  module Api
    # Read-only assembly using current declarations and executor announcements.
    # Execution accepts and freezes its own tools and environment later.
    ToolAssembly = Data.define(:tool_definitions, :environment)

    # WHAT THE KERNEL CAN DO FOR A MODEL, and the bytes that ask for it.
    #
    # A kernel tool is declared by the AGENT, per model task, exactly like
    # any other — the kernel holds no notion of a mode, so "this run can
    # wait" is an agent-side decision recorded in its authorized declaration.
    # An eager entry reaches the provider's `tools`; deferred schemas are
    # discovered through the same frozen declaration. What makes this a fetch
    # rather than a constant is that the declaration must be BYTE-
    # IDENTICAL to the registry's: a paraphrase is refused
    # `kernel_tool_redefined`, and a copy carried in this gem would go
    # stale the round a description was reworded.
    #
    # A source declaration can name exact `kernel_tools` for Nexus to import.
    # A kernel tool may also be declared under the agent's own
    # name for it — an ALIAS entry (`alias`, below): the canonical stays
    # the kernel's, the kernel renders the texts with the declared names
    # at declaration, and a call made under the alias runs under the
    # kernel's wire name. This gem builds the shape and nothing more.
    class ToolCatalog
      include Parsing

      # `template` is the macro-bearing SOURCE of the description (`{{delegate_task}}`
      # unrendered), the field the kernel serves so a pack's `recut` can
      # edit it (`CybrosAgent::ModelAdaptations`); nil from a kernel that
      # serves no template.
      Entry = Data.define(:canonical_name, :name, :effect_profile, :definition, :template) do
        def initialize(canonical_name:, name:, effect_profile:, definition:, template: nil) = super
      end

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      # Every live kernel tool. `definition` splices straight into a
      # task's `tools` array.
      def list
        body = @dispatch.call("/agent_api/v1/tools")
        shapes(Entry, body, "tools")
      end

      # The declarations for the canonical names given, in the order
      # asked. A name the kernel does not serve is an ERROR rather than a
      # silent omission: a caller that asked for `wait` and got a run
      # without it would learn only from the model's behaviour, several
      # rounds and one bill later.
      def definitions_for(canonical_names)
        return [] if canonical_names.empty?

        catalog = list.to_h { |entry| [entry.canonical_name, entry] }
        canonical_names.map do |name|
          entry = catalog[name]
          raise UnknownKernelTool, "the kernel serves no tool named #{name}" if entry.nil?

          entry.definition
        end
      end

      # Resolve exact callable names and routes without creating work. Omitting
      # configuration uses the caller's standing declaration; an explicit block
      # previews those sources. The nullable Runner selection always rides.
      def assemble(default_runner_executor_public_id: nil, configuration: nil)
        body = { "default_runner_executor_public_id" => default_runner_executor_public_id }
        body["configuration"] = configuration unless configuration.nil?
        shape(ToolAssembly, @dispatch.call("/agent_api/v1/tools/assembly", method: :post, body: body))
      end

      # AN ALIAS ENTRY, compact: `{type, function: {name}, canonical,
      # params?, omit?, description?, defer_loading?}` — splices into `tool_definitions`
      # beside the catalog's bytes. `params` maps the agent's parameter
      # names onto the kernel's (`{run_in_background: {maps_to: "wait",
      # invert: true, description: "…"}}`; an inverted boolean needs its
      # own sentence), `omit` drops kernel parameters the alias never
      # exposes, `description` replaces the kernel's text (a template: a
      # `{{delegate_task}}`-style macro spells a kernel tool as this profile names
      # it). `defer_loading` controls schema exposure, not execution authority.
      # Empty facts are dropped; the kernel is the one validator.
      def alias(name:, canonical:, params: {}, omit: [], description: nil, defer_loading: nil)
        facts = {
          "canonical" => canonical.to_s,
          "params" => params.to_h { |param, spec| [param.to_s, spec.to_h.transform_keys(&:to_s)] },
          "omit" => omit.map(&:to_s),
          "description" => description,
          "defer_loading" => defer_loading,
        }.reject { |_key, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }
        { "type" => "function", "function" => { "name" => name.to_s } }.merge(facts)
      end

      SHAPES = {
        ToolAssembly => { tool_definitions: :json_array, environment: :json_object },
        Entry => {
          canonical_name: :string,
          name: :string,
          effect_profile: :json_object_or_empty,
          definition: :json_object_or_empty,
          template: :optional_string,
        },
      }.freeze
    end

    # Asked for a kernel tool this kernel does not serve.
    class UnknownKernelTool < Error; end
  end
end
