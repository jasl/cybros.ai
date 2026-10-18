module CybrosAgent
  module Api
    # THE STORE, behind three member-plane doors that share one grammar.
    # One context, three handles: `workspace.store_entries`,
    # `conversation.store_entries`, `client.profile.store_entries`. The
    # route decides whose store it is — the workspace's, the conversation's
    # (which forks with it), or the ACTING principal's own row — and the
    # same body, projections and `Idempotency-Key` rule hold on all three.
    # The profile door keeps no receipt, so a retried create there is
    # `Conflict key_taken`, never a replay.
    #
    # Stores remain application-private. A domain operation may project a
    # purposeful result, but a raw store is never a model memory source.
    #
    # `value` is opaque JSON in both directions: a stored JSON null is a
    # legal value, so the field always travels — an explicit nil MUST
    # become null on the wire and arrive back as a present-and-nil member
    # of the Full projection.
    class StoreEntriesContext
      include WorkspaceProjections
      include Fields

      Created = Data.define(:store_entry, :replayed) do
        def replayed? = replayed
      end

      attr_reader :path

      # `path` is the door: the store collection this context reads and
      # writes, already spelled by the owning context.
      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = required_string_snapshot(path, "path")
      end

      def list(after: nil, limit: nil, order: nil)
        page(StoreEntrySummary, @dispatch.call(path, params: query(after:, limit:, order:)), "store_entries")
      end

      # Creation demands the caller's own Idempotency-Key — the SDK never
      # silently mints one.
      def create(namespace:, key:, value:, idempotency_key:)
        required_string(idempotency_key, "idempotency_key")

        answer = @dispatch.call_accepting(
          path,
          method: :post,
          body: { "store_entry" => { "namespace" => namespace, "key" => key, "value" => value } },
          headers: { "Idempotency-Key" => idempotency_key },
          success: 201
        )
        Created.new(store_entry: shape(StoreEntry, answer.body, "store_entry"), replayed: answer.replayed)
      end

      def fetch(public_id)
        shape(StoreEntry, @dispatch.call(entry_path(public_id)), "store_entry")
      end

      def update(public_id, value:, lock_version:)
        answer = @dispatch.call(
          entry_path(public_id),
          method: :patch,
          body: { "store_entry" => { "value" => value, "lock_version" => lock_version } }
        )
        shape(StoreEntry, answer, "store_entry")
      end

      # Deletion is the family's one empty answer: 204, and nil here.
      def delete(public_id, lock_version:)
        @dispatch.call(
          entry_path(public_id),
          method: :delete,
          params: { "lock_version" => lock_version },
          success: 204
        )
        nil
      end

      private

        def entry_path(public_id)
          "#{path}/#{path_segment(public_id, "public_id")}"
        end
    end
  end
end
