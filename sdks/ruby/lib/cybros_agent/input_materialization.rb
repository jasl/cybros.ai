module CybrosAgent
  # Correlates one accepted input with its execution through the existing
  # durable feed. The application owns polling, deadlines and storage of the
  # pre-acceptance position; this projection owns no separate receipt lifecycle.
  class InputMaterialization
    Result = Data.define(:turn, :variant, :run_public_id) do
      def self.from_materialization(value)
        new(turn: value.turn_public_id, variant: value.variant_public_id, run_public_id: value.run_public_id) if value
      end
    end

    attr_reader :result, :blocked_reason, :compaction

    def initialize(input_public_id:, replay:, position: KernelFeed::Position.start, recover: nil)
      @input_public_id = input_public_id
      @recover = recover
      @restored_head = nil
      @replay_gap = false
      @result = nil
      @blocked_reason = nil
      @compaction = nil
      @feed = KernelFeed.new(position: position, replay: replay, after_replay: method(:recover_materialization))
    end

    def position = @feed.position

    def refresh
      @feed.each do |event|
        @replay_gap = true if event.sequence > @feed.position.sequence + 1
        apply(event)
      end
      self
    end

    private

      def apply(event)
        payload = event.payload
        case event.type
        when "input_blocked"
          if payload["input_public_id"] == @input_public_id && payload["blocked_reason"] != "run_held"
            @blocked_reason = payload.fetch("blocked_reason")
          end
        when "input_materialized"
          if payload["input_public_id"] == @input_public_id
            @result ||= execution(payload)
            @blocked_reason = nil
          end
        when "turn_status"
          @compaction = execution(payload) if payload["turn_kind"] == "compaction_summary"
        else nil
        end
      end

      def execution(payload)
        Result.new(turn: payload["turn_public_id"], variant: payload["variant_public_id"],
          run_public_id: payload["run_public_id"])
      end

      # A gap can precede retained items even when the last retained sequence
      # reaches the head. Recover only after the complete frozen replay, and
      # never invent a consumed cursor or replace an already correlated run.
      def recover_materialization(head)
        return if @result || @recover.nil? || head.nil? || head == @restored_head

        if @replay_gap || head > @feed.position.sequence
          @result = @recover.call(@input_public_id)
          @blocked_reason = nil if @result
          @restored_head = head
          @replay_gap = false
        end
      end
  end
end
