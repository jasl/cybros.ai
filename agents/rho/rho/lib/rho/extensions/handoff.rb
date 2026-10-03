require_relative "handoff/tree_sync"
require_relative "handoff/routes"
require_relative "handoff/commands"

module Rho
  module Extensions
    # THE HANDOFF: the runners this profile may address, listed with
    # this daemon's marks; the settings' selection new hosts start on,
    # written from the CLI process; and the one verb that moves where a
    # followed host's runner-kind calls land — refused here when the
    # target's bytes collide with what the profile declares, bound through
    # the SDK otherwise, the next turn re-rendered for it. It syncs no
    # tree: the host filesystem is implicit state, which is why the switch
    # is never implicit — the person moves the checkout. Shipped in full
    # and agent mode; a runner opens no conversation and holds no member
    # plane, so it ships without it.
    module Handoff
      NAME = "rho.handoff".freeze

      def self.register(api)
        Routes.register(api)
        register_commands(api)
      end

      def self.register_commands(api)
        api.register_command("runners", usage: "runners [use] [ID]",
          description: "List the runners this profile may address (`use ID` selects one for new conversations, " \
                       "--none clears the selection)",
          options: { none: { type: :boolean, default: false,
                             desc: "Clear the selection: new conversations start on this machine's own runner" } },
          &Commands.method(:runners))
        api.register_command("handoff", usage: "handoff HOST_ID EXECUTOR_ID",
          description: "Recovery: move a followed conversation or loop's tool calls to another runner " \
                       "after its runner died or was replaced (unclaimed calls move now; a running one settles " \
                       "where it started; the tree is not synced)",
          &Commands.method(:handoff))
      end
    end
  end
end
