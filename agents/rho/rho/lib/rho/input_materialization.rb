require "cybros_agent"

module Rho
  # A request's input receipt projected from the durable host feed. The
  # starting position precedes the POST; it can be replayed by a surface
  # continuing a pending receipt without retaining daemon-side state.
  class InputMaterialization
    Result = Data.define(:turn, :loop)

    attr_reader :result, :blocked_reason, :compaction

    def initialize(input_public_id:, position:, replay:)
      @input_public_id = input_public_id
      @feed = CybrosAgent::KernelFeed.new(position: position, replay: replay)
      @turn = nil
      @result = nil
      @blocked_reason = nil
      @compaction = nil
    end

    def refresh
      @feed.each { |event| apply(event) }
      self
    end

    private

      def apply(event)
        payload = event.payload
        case event.type
        when "input_blocked"
          return if payload["blocked_reason"] == "loop_held"

          @blocked_reason = payload.fetch("blocked_reason") if payload["input_public_id"] == @input_public_id
        when "input_materialized"
          return unless payload["input_public_id"] == @input_public_id

          @turn = payload["turn_public_id"]
          @blocked_reason = nil
          @result = Result.new(turn: @turn, loop: payload["agent_loop_public_id"]) if payload["agent_loop_public_id"]
        when "turn_status"
          if payload["turn_kind"] == "compaction_summary"
            @compaction = Result.new(turn: payload.fetch("turn_public_id"), loop: payload["agent_loop_public_id"])
          elsif @turn && payload["turn_public_id"] == @turn
            @result ||= Result.new(turn: @turn, loop: payload["agent_loop_public_id"])
          end
        when "turn_created"
          if @turn && payload["turn_public_id"] == @turn && payload["kind"] == "message"
            @result ||= Result.new(turn: @turn, loop: nil)
          end
        else nil
        end
      end
  end
end
