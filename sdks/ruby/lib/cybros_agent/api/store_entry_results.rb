module CybrosAgent
  module Api
    # Typed projections of a Workspace's StoreEntries. The Basic
    # type has no `value` member at all, so an omitted list value can never be
    # confused with a stored JSON null — only the Full type answers the
    # question "what is stored here".

    StoreEntrySummary = Data.define(
      :public_id, :namespace, :key, :lock_version, :created_at, :updated_at
    ) do
      include Redacted

      def inspect = redacted(public_id:, namespace:, key:, lock_version:, created_at:, updated_at:)
    end

    # The Full projection. `value` is application-owned JSON that may carry
    # credentials, so every diagnostic redacts it.
    StoreEntry = Data.define(
      :public_id, :namespace, :key, :lock_version, :created_at, :updated_at, :value
    ) do
      include Redacted

      def inspect
        redacted(public_id:, namespace:, key:, lock_version:, created_at:, updated_at:, hidden: %i[value])
      end
    end
  end
end
