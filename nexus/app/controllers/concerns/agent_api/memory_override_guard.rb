# THE OVERRIDE GUARD the two workspace-bound memory doors share: while a
# workspace has opted its memory family into a tools provider, the kernel's
# rows wait for the clear and the door refuses `memory_overridden` (409,
# naming the provider) for reads and writes alike. EXCEPT A `skills/` PATH:
# a skill is the kernel's instruction row, never the provider's — the
# prefix is the kernel's, the model never writes it, the load reads it
# in-process — so a verb naming one passes under an override. The person's
# own door (`profile/memory`) includes nothing of this: its `user/` rows
# are the kernel's in every workspace.
module AgentAPI::MemoryOverrideGuard
  extend ActiveSupport::Concern

  private

    # The door's own fact, not a service refusal (so not the family map's):
    # one lock-free read of the workspace, before any row funnel — a
    # workspace fact stays in front. True to go on; false after rendering.
    def not_overridden(workspace, path: nil)
      return true if path && Nexus::Skills.reserved?(Scopes::Anchor.split(path).last)

      override = workspace.tool_provider_override_for("memory_read")
      return true if override.nil?

      provider = workspace.tool_provider_for("memory_read")
      render_error(:memory_overridden,
        "Memory in this workspace is served by #{provider&.display_name || override}", status: :conflict)
      false
    end
end
