module RhoAcpTest
  # The durable event read is separate from the daemon's live UI stream.
  # Tests can advance either independently, as two queued senders do.
  class MaterializationCore < CoreDouble
    POSITION = { "cursor" => "cursor_1", "sequence" => 1 }.freeze

    attr_accessor :variant_rows

    def initialize(**)
      super
      @host_events = []
      @variant_rows = []
      publish("turn_created", turn_public_id: "trn_prior", kind: "message", status: "completed")
    end

    def pending_receipt(input: "cin_editor")
      { "input" => { "public_id" => input, "state" => "pending", "position" => POSITION.dup }, "pending" => true }
    end

    def publish(type, **payload)
      @lock.synchronize do
        sequence = (@host_events.last&.sequence || 0) + 1
        @host_events << CybrosAgent::Api::ConversationEvent.new(
          public_id: "evt_#{sequence}", sequence: sequence, cursor: "cursor_#{sequence}", type: type,
          resource_type: "conversation", resource_public_id: "cnv_1", occurred_at: "2026-09-20T00:00:00Z",
          payload: payload.transform_keys(&:to_s)
        )
      end
    end

    def host_events(public_id, after: nil, limit: nil)
      record(:host_events, public_id, after: after, limit: limit)
      refuse!(:host_events)
      @lock.synchronize do
        offset = after.nil? ? 0 : @host_events.index { |event| event.cursor == after } + 1
        CybrosAgent::Api::ConversationEventPage.new(items: @host_events.drop(offset), next_after: nil,
          watermark: @host_events.last&.sequence || POSITION.fetch("sequence"))
      end
    end

    def variants(public_id, turn)
      record(:variants, public_id, turn)
      @variant_rows
    end
  end
end
