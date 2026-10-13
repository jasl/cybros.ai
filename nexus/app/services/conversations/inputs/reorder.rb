module Conversations
  module Inputs
    # Exact-set renumbering of the PRINCIPALS' rows (a person's and a
    # peer's `send` alike): a partial list would silently reorder rows the
    # caller never saw, and a kernel-origin row is not theirs to move — it
    # reads first by the read rule, keeps its arrival number, and naming
    # it refuses by name. The principals' rows swap among their own
    # positions, so nothing collides with a kernel row's. Two phases
    # because the FIFO index is unique.
    class Reorder
      # Far above any real queue (the caller-authored bound is two digits).
      SHIFT = 1_000_000

      Command = Data.define(:host, :ordered_public_ids, :acting_user)

      class << self
        def call(command)
          new(command).call
        end
      end

      def initialize(command)
        @command = command
        @host = command.host
      end

      def call
        unless @host.writable_by?(@command.acting_user)
          return Outcome.refused(:not_authorized)
        end

        result = @host.with_lock { locked_reorder }
        @host.wake_drain if result.accepted?
        result
      end

      private

        def locked_reorder
          refusal = @host.input_refusal
          return Outcome.refused(refusal) if refusal

          submitted = @command.ordered_public_ids.map(&:to_s)
          if @host.conversation_inputs.where(origin: ConversationInput::KERNEL_ORIGINS)
              .where(public_id: submitted).exists?
            return Outcome.refused(:kernel_input_immutable)
          end

          rows = @host.conversation_inputs
            .where(state: ConversationInput::STATES).where.not(origin: ConversationInput::KERNEL_ORIGINS)
            .index_by(&:public_id)
          unless submitted.sort == rows.keys.sort
            return Outcome.refused(:queue_changed)
          end

          ordered = submitted.map { |public_id| rows.fetch(public_id) }
          moved = renumber(ordered)
          narrate(moved) if moved.any?
          Outcome.accepted(ordered)
        end

        def renumber(ordered)
          positions = ordered.map(&:queue_position).sort
          targets = ordered.each_with_index.filter_map do |input, index|
            [input, index] if input.queue_position != positions[index]
          end
          return [] if targets.empty?

          ordered.each do |input|
            input.update_column(:queue_position, input.queue_position + SHIFT)
          end
          ordered.each_with_index do |input, index|
            input.update_column(:queue_position, positions[index])
          end
          targets.map(&:first)
        end

        def narrate(moved)
          ConversationEvent::Append.call(
            host: @host,
            items: moved.map do |input|
              {
                type: "input_edited",
                payload: {
                  "input_public_id" => input.public_id,
                  "queue_position" => input.queue_position,
                  "state" => input.state,
                },
              }
            end
          )
        end
    end
  end
end
