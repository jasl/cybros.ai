module InferenceRequestEvents
  # The InferenceRequest plane's durable append: same-key replay before any write,
  # cursor-lock-serialized sequences, items rendered through the replay
  # projection. Every appender holds the InferenceRequest row, so no race rescue.
  class Append
    def self.call(...) = new(...).call

    # A fresh identity by default (each delta is its own fact); the
    # terminal writer passes the invocation's public id.
    def initialize(inference_request:, items:, idempotency_key: SecureRandom.uuid_v7,
                   occurred_at: DatabaseClock.now)
      @inference_request = inference_request
      @items = items
      @idempotency_key = idempotency_key
      @occurred_at = occurred_at
    end

    def call
      raise ArgumentError, "items must be present" if @items.empty?

      existing = @inference_request.inference_request_events.find_by(idempotency_key: @idempotency_key)
      return existing if existing

      cursor = ensure_event_cursor
      ApplicationRecord.transaction do
        event = @inference_request.inference_request_events.create!(
          account_id: @inference_request.account_id,
          idempotency_key: @idempotency_key
        )
        sequences = cursor.allocate_sequences(@items.length).to_a
        created = @items.each_with_index.map do |item, index|
          event.inference_request_event_items.create!(
            account_id: @inference_request.account_id,
            inference_request: @inference_request,
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
        rendered = created_items.map { |item| InferenceRequestEventItem::PublicProjection.render(item) }
        public_id = @inference_request.public_id
        ApplicationRecord.current_transaction.after_commit do
          rendered.each do |event_item|
            RealtimeEvents::Broadcast.call(
              resource_type: "inference_request", resource_public_id: public_id, event_item: event_item
            )
          end
        end
      end

      def ensure_event_cursor
        @inference_request.inference_request_event_cursor ||
          InferenceRequestEventCursor.create!(inference_request: @inference_request, account_id: @inference_request.account_id)
      end
  end
end
