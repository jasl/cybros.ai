module CybrosAgent
  # THE KERNEL'S TOOLS BY CAPABILITY — names, never bytes. A declaration
  # names the kernel tools it wants (`kernel_tools:`) and Nexus imports
  # their published definitions; what a caller otherwise hand-assembles is
  # a list of canonical strings, which is where a typo turns into a model
  # that quietly cannot delegate. These are the groups an application
  # actually reaches for, each a frozen list of canonical names.
  #
  # BYTES STAY THE KERNEL'S: no schema, no description and no alias rides
  # here — a copy of either would go stale the round the kernel reworded
  # one (`Api::ToolCatalog`). A deployment that serves another set is the
  # reason `verify` exists; nothing in this module reaches the network on
  # its own.
  module Toolsets
    # Branch, park, and ask the person: the graph's two and the human door.
    ORCHESTRATION = %w[
      nexus.graph.delegate_task
      nexus.graph.wait
      nexus.human.ask
    ].freeze

    # Talk to other conversations: spawn a child, send to a peer, read its
    # state, stop it, request a reply, and manage message links.
    CONVERSATION = %w[
      nexus.conversation.spawn
      nexus.conversation.send
      nexus.conversation.request
      nexus.conversation.links
      nexus.conversation.status
      nexus.conversation.cancel
    ].freeze

    # Read back what was said: keyword search across readable
    # conversations and the bounded window read.
    HISTORY = %w[
      nexus.conversation.search
      nexus.conversation.read
    ].freeze

    # The durable documents a reply assembles from, as the model's own
    # file-style verbs.
    MEMORY = %w[
      nexus.memory.read
      nexus.memory.write
      nexus.memory.edit
      nexus.memory.ls
      nexus.memory.grep
      nexus.memory.delete
    ].freeze

    # Find a callable without carrying its schema in the prefix, call it,
    # and see which Runner environments this execution may address.
    DISCOVERY = %w[
      nexus.tools.search
      nexus.tools.call
      nexus.runners.list
      nexus.models.list
    ].freeze

    # Load a document from the turn's frozen skill catalog.
    SKILLS = %w[
      nexus.skill.load
    ].freeze

    IMAGES = %w[nexus.image.generate].freeze
    SCHEDULES = %w[nexus.schedules.read nexus.schedules.manage].freeze

    SETS = {
      orchestration: ORCHESTRATION,
      conversation: CONVERSATION,
      history: HISTORY,
      memory: MEMORY,
      discovery: DISCOVERY,
      skills: SKILLS,
      images: IMAGES,
      schedules: SCHEDULES,
    }.freeze

    # Every name the groups above hold, in group order.
    ALL = SETS.values.flatten.freeze

    class << self
      # The canonical names of the groups asked for, deduplicated and in
      # the order asked — the array `declare_configuration(kernel_tools:)`
      # takes. A word that names no group is an ArgumentError here rather
      # than a silently thinner declaration the model discovers for you.
      def names(*sets)
        sets.flatten.flat_map { |set| SETS.fetch(set.to_sym) { raise ArgumentError, "unknown toolset #{set}" } }
          .uniq.freeze
      end

      # WHAT THIS DEPLOYMENT ACTUALLY SERVES, checked once and explicitly:
      # one catalog read, and every name asked for that the kernel does not
      # publish is named in the refusal together. Answers the same array
      # `names` would, so a boot path can check and declare in one
      # expression. Called by nobody automatically — a declaration must not
      # pay a round trip for a constant.
      def verify(client, *sets)
        asked = sets.empty? ? ALL : names(*sets)
        missing = asked - client.tools.list.map(&:canonical_name)
        raise Api::UnknownKernelTool, "this deployment serves no #{missing.join(", ")}" if missing.any?

        asked
      end
    end
  end
end
