class ConversationEvent
  # The one hosted plane's durable append: same-key replay before any write,
  # cursor-lock-serialized sequences, items rendered through the replay
  # projection. A loop-locked appender never holds a conversation host's
  # row, so the key and the cursor both rescue their race.
  class Append
    def self.call(...) = new(...).call

    # The default key is a fresh identity; a host-locked command writer
    # passes its product's public id for a one-per-command replay contract.
    def initialize(host:, items:, idempotency_key: SecureRandom.uuid_v7,
                   occurred_at: DatabaseClock.now)
      @host = host
      @items = items
      @idempotency_key = idempotency_key
      @occurred_at = occurred_at
    end

    def call
      raise ArgumentError, "items must be present" if @items.empty?

      existing = replayed
      return existing if existing

      cursor = ensure_event_cursor
      ApplicationRecord.transaction do
        event = new_envelope
        # The key race: another lane landed this key between the pre-check
        # and the insert — its envelope is the answer, nothing is written.
        next replayed if event.nil?

        sequences = cursor.allocate_sequences(@items.length).to_a
        created = @items.each_with_index.map do |item, index|
          event.conversation_event_items.create!(
            account_id: @host.account_id,
            host: @host,
            sequence: sequences.fetch(index),
            item_type: item.fetch(:type),
            payload: item.fetch(:payload),
            occurred_at: item[:occurred_at] || @occurred_at
          )
        end
        broadcast_after_commit(created)
        event
      end
    end

    private

      def replayed
        @host.conversation_events.find_by(idempotency_key: @idempotency_key)
      end

      # A savepoint around the insert, so the unique-index loser leaves the
      # enclosing transaction usable.
      def new_envelope
        ApplicationRecord.transaction(requires_new: true) do
          @host.conversation_events.create!(
            account_id: @host.account_id, idempotency_key: @idempotency_key
          )
        end
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      def broadcast_after_commit(created_items)
        rendered = created_items.map { |item| ConversationEventItem::PublicProjection.render(item) }
        resource_type = @host.model_name.singular
        public_id = @host.public_id
        ApplicationRecord.current_transaction.after_commit do
          rendered.each do |event_item|
            RealtimeEvents::Broadcast.call(
              resource_type: resource_type, resource_public_id: public_id,
              event_item: event_item
            )
          end
        end
      end

      # The cursor is created WITH its host; this is the backstop for a host
      # built outside its creator, race-safe by the index.
      def ensure_event_cursor
        @host.conversation_event_cursor ||
          ConversationEventCursor.create_or_find_by!(host: @host)
      end
  end
end
