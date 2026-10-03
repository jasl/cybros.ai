require "rho/runner"

module Rho
  module Extensions
    # THE IMAGE TOOL:
    # a model that can ask for an image. Codex ships `image_gen.imagegen`
    # on a hardcoded `gpt-image-2` (`tool.rs:59`); opencode and Claude Code
    # ship none. Taken because the kernel already owns the model call and
    # the workload exists: one tool on the agent's own address, one
    # OneShot on the `image_generation` workload, on the model the
    # settings name (`image_model` — a SETTING, never a hardcoded id),
    # keyed by the call, followed under the runner's clamp, its bytes
    # fetched through the SDK's existing download route and written under
    # the environment root as a `files:` capture the run uploads — so the
    # image re-enters the transcript exactly as `read` attaches one.
    #
    # A SHIPPED EXTENSION, the Compaction/Todo precedent: the tool needs
    # the member plane, so it is the AGENT's tool, registered
    # `serves: :agent`, excluded in runner mode. THE GATE IS THE SETTING:
    # no `image_model`, no tool — the extension registers nothing and
    # announces nothing (the Checkpoints shape, "graceful by
    # construction"). Whether the named row is one this account may run
    # on the image workload is the kernel's selection to judge, at every
    # call (a refusal there is relayed as text the model reads): the
    # member plane is born after the extensions register, so no catalog
    # can be read at registration, and a second lookup beside the kernel's
    # would be a second implementation of one mechanism.
    #
    # THE SPELLING FOLLOWS THE BOOT ROW: `image_generate` plain; `imagegen`
    # under a boot row whose `tool_style` names `codex` (the `SPELLINGS`
    # table on the tool). Rho's OWN switch, not a `presets.yml` alias: the
    # kernel's alias grammar takes a KERNEL canonical only
    # (`Nexus::ToolDeclarations` answers `alias_canonical_unknown` for an
    # executor's tool), so the pack's alias tables cannot spell a tool this
    # daemon serves.
    module Images
      NAME = "rho.images".freeze
      CODEX = "codex".freeze

      def self.register(api)
        config = api.host&.config
        return if config&.image_model.nil?

        ImageGenerate.bind(member_plane: api.host&.member_plane, config: config, log: api.host&.log)
        api.register_tool(ImageGenerate.spelled(boot_styles(config, api.host&.home)), serves: :agent)
      end

      # The boot row's styles — the universe the profile declares — read
      # off the pack the settings name; none under a host with no home.
      def self.boot_styles(config, home)
        return [] if home.nil?

        Rho::Adaptations.load(config, home: home).boot.row.tool_style
      end
    end
  end
end

require_relative "images/image_generate"
