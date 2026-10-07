require "rho/runner"

module Rho
  module Extensions
    # THE TODO TRACKER: one tool on the agent's own address, `todo_write`, that keeps the
    # model's plan as a checklist the person can see. The list is TEXT THE MODEL READS
    # (memory, never a store row), so its home is the kernel's memory family — the
    # conversation's own document `conversation/todo.md`, written whole through the member
    # plane's conversation door, rendered by the kernel into the next turn's memory block
    # and read by the webui through the same door. Nothing in the kernel changes; the daemon
    # keeps no table (the person's view is transcript-derived,
    # `Cli::Reporting#report_todo`).
    #
    # A SHIPPED EXTENSION, the Compaction precedent: the tool needs no
    # environment — it writes a kernel document — so it is the AGENT's tool,
    # registered `serves: :agent`, and excluded in runner mode for the same
    # reason Compaction is (a runner opens no conversation and holds no
    # member plane). The member plane is a CALLABLE bound at registration,
    # dereferenced when the tool runs; nil under a loader with no daemon.
    module Todo
      NAME = "rho.todo".freeze
      # The conversation is the scope anchor, so the memory key names one document within that
      # scope.
      DOCUMENT = "conversation/todo.md".freeze

      def self.register(api)
        Write.bind(member_plane: api.host&.member_plane, log: api.host&.log)
        api.register_tool(Write, serves: :agent)
      end
    end
  end
end

require_relative "todo/write"
