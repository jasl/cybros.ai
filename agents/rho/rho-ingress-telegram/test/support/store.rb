module TelegramStateSupport
  Row = Data.define(:public_id, :namespace, :key, :lock_version, :value)
  Page = Data.define(:items, :next_after)

  class Store
    attr_reader :rows, :writes

    def initialize
      @rows, @writes = {}, []
    end

    def list(**) = Page.new(items: @rows.values, next_after: nil)
    def fetch(id) = @rows.fetch(id)

    def create(namespace:, key:, value:, idempotency_key:)
      if @rows.values.any? { |row| row.namespace == namespace && row.key == key }
        raise CybrosAgent::Api::Conflict.new("already created", code: "key_taken")
      end

      id = "store-#{@rows.length + 1}"
      @writes << value
      @rows[id] = Row.new(public_id: id, namespace: namespace, key: key, lock_version: 0, value: copy(value))
    end

    def update(id, value:, lock_version:)
      row = @rows.fetch(id)
      raise CybrosAgent::Api::Conflict.new("stale", code: "stale_object") unless row.lock_version == lock_version

      @writes << value
      @rows[id] = row.with(value: copy(value), lock_version: lock_version + 1)
    end

    private

      def copy(value) = JSON.parse(JSON.generate(value))
  end

  def self.store(home)
    @stores ||= {}
    @stores[home.root] ||= Store.new
  end

  def self.document(home)
    Rho::StoreDocument.new(store: -> { store(home) }, namespace: "rho.telegram", key: "state")
  end
end
