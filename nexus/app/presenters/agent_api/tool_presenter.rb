module AgentAPI
  # The kernel tool catalog as `GET /tools` serves it — the bytes a task
  # must send to turn one on under its plain name, since
  # `kernel_tool_redefined` refuses any declaration that is not byte-
  # identical to the registry's. This is the UN-ALIASED render: a profile
  # that declares its own spelling (an alias entry) receives its texts
  # re-spelled at declaration, never here. ONE renderer: the controller and
  # the contract pack's fixture both read it, so the pack cannot describe a
  # listing the route does not serve.
  class ToolPresenter
    class << self
      def index
        Nexus::ToolRegistry.live_names.map { |canonical| row(canonical) }
      end

      private

        # The three-segment canonical name, the wire spelling a model sees,
        # the declaration itself, and the macro-bearing SOURCE of the
        # description (`{{task}}` unrendered) — `template` is what lets an
        # adaptation pack re-cut ONE anchored paragraph of a description
        # against the kernel's own bytes instead of carrying a copy of
        # them. A client needs the definition; the rest is what makes a
        # refusal legible and a recut honest.
        def row(canonical)
          {
            canonical_name: canonical,
            name: Nexus::ToolRegistry.wire_schema_for(canonical).fetch("name"),
            effect_profile: Nexus::ToolRegistry.effect_profile_for(canonical),
            definition: Nexus::ToolRegistry.function_definition(canonical),
            template: Nexus::ToolRegistry.entry(canonical).template,
          }
        end
    end
  end
end
