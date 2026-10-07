module CybrosAgent
  module Api
    # THIS EXECUTOR'S INBOX — every row the kernel addressed to this
    # credential's executor across every live run, level-triggered. The workspace is not a scope here: the address is, and
    # the credential names it, so nothing is submitted by the caller.
    #
    # It is the TRUTH. The realtime `work_available` on the executor's own
    # channel names a kind, a run, a task key and a tool name and carries
    # nothing executable, so losing a frame costs milliseconds and never a
    # task: a runner that slept, crashed, restarted or never connected
    # recovers completely by reading this.
    #
    # IT STAYS COMPLETE — claimed rows included — because a runner returning
    # from a crash must be able to see the work it already holds. `claimed`
    # is EVER claimed in this generation: a lapsed claim is not re-granted,
    # expiry is the sweep's alone.
    #
    # There is no blocking spelling and no built-in poll loop. A runner
    # chooses its own interval, its own backoff and its own deadline; hiding
    # them here would hide them from the only code that can choose them.
    class ExecutorInboxContext
      include RunProjections
      include Fields

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      # `after` is an opaque cursor from a previous page's `next_after` —
      # never constructed, never parsed.
      def list(after: nil, limit: nil)
        page(InboxTask, @dispatch.call(ExecutorClient::INBOX_PATH, params: query(after:, limit:)), "tasks")
      end
    end
  end
end
