module AgentLoops
  # THE MODEL A ROUND'S LINEAGE WAS CONFIGURED WITH — where new work it
  # starts begins: a composed member, a delegated `task`, the model a
  # `spawn` or `send` names by default. A round moved to the answerer's
  # fallback because its model refused or was overloaded keeps running there
  # for the rest of its turn (the vendors' "stay on the fallback"), but work
  # it STARTS is new: an overload is transient, and a refusal is about the
  # request that drew it, so new work begins where the lineage was put.
  #
  # The walk is the round's own reading chain through every compaction cut
  # (a summary replaces what a round reads, never where its lineage began):
  # the OLDEST round whose row carries the switch's fact answers its first
  # cause's own trio — the columns the refused or overloaded invocation was
  # sealed with, effort included. A cause that did not switch (a fallback
  # overloaded in turn stands where it is) moves nothing, and no switch on
  # the chain answers the round's own trio. So a step its author put on a
  # model keeps that model (its chain has no switch), and a mail loop the
  # unavailable rung moved to the default model reads the default (an
  # unavailable model is no switch cause, and there is nothing to return to).
  module ConfiguredModel
    Trio = Data.define(:provider_id, :model_ref, :reasoning_effort) do
      # The model member a step authors with.
      def model = { "model" => "#{provider_id}/#{model_ref}", "reasoning_effort" => reasoning_effort }.compact
    end

    module_function

    def for(round)
      switched = lineage(round).reverse_each.find do |row|
        ModelFallback::SWITCH_REASONS.include?(row.output_summary.dig("model_change", "reason"))
      end
      source = (ModelFallback.switch_causes_of(switched).first if switched) || round
      Trio.new(provider_id: source.provider_id, model_ref: source.model_ref, reasoning_effort: source.reasoning_effort)
    end

    # The round and its reading chain, newest first, segment by segment
    # past each marked round. Terminates: every segment steps to a strictly
    # older row of the loop's finite graph, and an empty one ends the walk.
    def lineage(round)
      rows = [round]
      loop do
        segment = Conversations::Compaction::Serialize.chain_segment(rows.last)
        break if segment.empty?

        rows.concat(segment.reverse)
      end
      rows
    end
  end
end
