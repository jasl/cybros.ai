# The store-host trait: a row that hosts `store_entries` — a
# Workspace, a Conversation, a User — answers the one door body's
# questions itself, so the five verbs branch on no host class. Every host
# answers four things, each a plain method beside this include:
#
#   store_write_refusal(user) nil when writable, else the typed refusal in
#                              concealment-first order (`:not_found` before
#                              the fence before operability)
#   with_store_create_lock(w) the ladder-ordered locks the create's cap
#                              count serializes on, yielding the locked writer
#   store_create_receipts(…) the configured idempotency wrapper for a
#                              create, or nil where the host keeps no receipt
#   store_receipt_success(…) the wrapper's own Success struct — asked only
#                              inside a wrapper's block, so a host that
#                              answers nil above never answers this
#
# The writer's lock is shared here: the same on every host.
# The profile host keeps NO receipt: the partial
# unique index and the `lock_version` CAS are its whole convergence
# contract, and a retried create is `key_taken`, never a replay.
module StoreHost
  extend ActiveSupport::Concern

  included do
    # Pure current values with no dependents of their own; each host's
    # teardown deletes them in-graph, leaves first.
    has_many :store_entries, dependent: :delete_all
  end

  private

    # The writer's own rows, in `PrincipalLocks`' order — an Agent before
    # the Human it derives from, id inside each kind. The steward is read
    # AFTER the writer's lock so a concurrent reassignment cannot leave the
    # standing recheck pointing at an unlocked Human; `lock!` reloads in
    # place, which is why the refusal read after this sees live standing.
    def lock_writer(writer)
      writer.lock!
      writer.steward&.lock! if writer.agent_member?
      writer
    end
end
