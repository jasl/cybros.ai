module Schedules
  # A page of ordinary child executions, including honest absence before the
  # input drains and after retained execution details are pruned.
  module ExecutionProjection
    module_function

    def call(conversation_ids)
      return {} if conversation_ids.empty?

      children = Conversation.where(id: conversation_ids).to_a
      inputs = Input.where(host_type: "Conversation", host_id: conversation_ids)
        .index_by(&:public_id)
      turns = Turn.where(public_id: children.filter_map(&:scheduled_turn_public_id)).index_by(&:public_id)
      variants = Variant.where(turn_id: turns.values.map(&:id))
        .where("position = 0 OR source = 'fallback'").to_a
      originals = variants.select { |variant| variant.position.zero? }.index_by(&:turn_id)
      fallbacks = variants.select { |variant| variant.source == "fallback" }.index_by(&:origin_variant_id)
      loops = Run.listable.where(variant_id: variants.map(&:id))
        .index_by(&:variant_id)

      children.to_h do |child|
        input = inputs[child.scheduled_input_public_id]
        turn = turns[child.scheduled_turn_public_id]
        variant = turn && originals[turn.id]
        if variant
          while (fallback = fallbacks[variant.id])
            variant = fallback
          end
        end
        loop = variant && loops[variant.id]
        [child.id, basic(child: child, input: input, turn: turn, variant: variant, run: loop)]
      end
    end

    def basic(child:, input:, turn:, run:, variant: nil)
      {
        child_conversation_public_id: child.public_id,
        input_public_id: child.scheduled_input_public_id,
        turn_public_id: turn&.public_id,
        variant_public_id: variant&.public_id,
        run_public_id: run&.public_id,
        scheduled_for: child.scheduled_for,
        status: input ? (input.blocked? ? "blocked" : "queued") : (run&.status || variant&.status || turn&.status || "canceled"),
        created_at: child.created_at,
      }
    end
  end
end
