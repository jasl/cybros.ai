module OneShotEvents
  # The OneShot plane's durable append: same-key replay before any write,
  # cursor-lock-serialized sequences, items rendered through the replay
  # projection. Every appender holds the OneShot row, so no race rescue.
  class Append
    def self.call(...) = new(...).call

    # A fresh identity by default (each delta is its own fact); the
    # terminal writer passes the invocation's public id.
    def initialize(one_shot:, items:, idempotency_key: SecureRandom.uuid_v7,
                   occurred_at: DatabaseClock.now)
      @one_shot = one_shot
      @items = items
      @idempotency_key = idempotency_key
      @occurred_at = occurred_at
    end

    def call
      raise ArgumentError, "items must be present" if @items.empty?

      existing = @one_shot.one_shot_events.find_by(idempotency_key: @idempotency_key)
      return existing if existing

      cursor = ensure_event_cursor
      ApplicationRecord.transaction do
        event = @one_shot.one_shot_events.create!(
          account_id: @one_shot.account_id,
          idempotency_key: @idempotency_key
        )
        sequences = cursor.allocate_sequences(@items.length).to_a
        created = @items.each_with_index.map do |item, index|
          event.one_shot_event_items.create!(
            account_id: @one_shot.account_id,
            one_shot: @one_shot,
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

      def broadcast_after_commit(created_items)
        rendered = created_items.map { |item| OneShotEventItem::PublicProjection.render(item) }
        public_id = @one_shot.public_id
        ApplicationRecord.current_transaction.after_commit do
          rendered.each do |event_item|
            RealtimeEvents::Broadcast.call(
              resource_type: "one_shot", resource_public_id: public_id, event_item: event_item
            )
          end
        end
      end

      def ensure_event_cursor
        @one_shot.one_shot_event_cursor ||
          OneShotEventCursor.create!(one_shot: @one_shot, account_id: @one_shot.account_id)
      end
  end
end
