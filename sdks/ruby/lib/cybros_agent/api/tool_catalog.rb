module CybrosAgent
  module Api
    # WHAT THE KERNEL CAN DO FOR A MODEL, and the bytes that ask for it.
    #
    # A kernel tool is declared by the AGENT, per model task, exactly like
    # any other — the kernel holds no notion of a mode, so "this loop can
    # compose" is an agent-side decision that reaches the wire as nothing
    # more than an entry appearing in `tools`. What makes this a fetch
    # rather than a constant is that the declaration must be BYTE-
    # IDENTICAL to the registry's: a paraphrase is refused
    # `kernel_tool_redefined`, and a copy carried in this gem would go
    # stale the round a description was reworded.
    #
    # The ONE other way to declare a kernel tool is under the agent's own
    # name for it — an ALIAS entry (`alias`, below): the canonical stays
    # the kernel's, the kernel renders the texts with the declared names
    # at declaration, and a call made under the alias runs under the
    # kernel's wire name. This gem builds the shape and nothing more.
    class ToolCatalog
      include Parsing

      # `template` is the macro-bearing SOURCE of the description (`{{task}}`
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
      # silent omission: a caller that asked for `compose` and got a loop
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

      # AN ALIAS ENTRY, compact: `{type, function: {name}, canonical,
      # params?, omit?, description?}` — splices into `tool_definitions`
      # beside the catalog's bytes. `params` maps the agent's parameter
      # names onto the kernel's (`{run_in_background: {maps_to: "wait",
      # invert: true, description: "…"}}`; an inverted boolean needs its
      # own sentence), `omit` drops kernel parameters the alias never
      # exposes, `description` replaces the kernel's text (a template: a
      # `{{task}}`-style macro spells a kernel tool as this profile names
      # it). Empty facts are dropped; the kernel is the one validator.
      def alias(name:, canonical:, params: {}, omit: [], description: nil)
        facts = {
          "canonical" => canonical.to_s,
          "params" => params.to_h { |param, spec| [param.to_s, spec.to_h.transform_keys(&:to_s)] },
          "omit" => omit.map(&:to_s),
          "description" => description,
        }.reject { |_key, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }
        { "type" => "function", "function" => { "name" => name.to_s } }.merge(facts)
      end

      SHAPES = {
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
