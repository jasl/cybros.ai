module Conversations
  # Content readers use the effective timeline. Execution links use their own
  # read funnel; inherited content never grants access to its source Run.
  class Reader
    PAGE_SIZE = 20
    Page = Data.define(:turns, :runs, :cost_refused_variant_ids, :before_position, :after_position, :has_older, :has_newer)
    VariantRead = Data.define(:entry, :variant, :run, :variant_record, :cost_refused)

    def initialize(conversation, user:)
      @conversation, @user = conversation, user
    end

    def page(around_turn_public_id: nil, after_position: nil, before_position: nil)
      timeline = @conversation.timeline
      from_position = if around_turn_public_id
        entry = timeline.entry(public_id: around_turn_public_id)
        raise ActiveRecord::RecordNotFound unless entry

        entry.position
      end
      entries = timeline.entries(surface: :timeline, after_position: after_position, before_position: before_position,
        from_position: from_position, newest: [from_position, after_position, before_position].all?(&:nil?), limit: PAGE_SIZE)
      turns = TurnProjection.turn_entries(entries, include_execution: false)
      variant_ids = turns.flat_map { |turn| [turn[:active_variant], turn[:running_variant]].compact.map { |variant| variant.fetch(:public_id) } }
      runs = Run.visible_to(@user).joins(:variant).where(variants: { public_id: variant_ids })
        .pluck("variants.public_id", "runs.public_id").to_h
      before, after = entries.first&.position, entries.last&.position
      # Only this host's direct replies can be regenerated here. Inherited
      # content conveys neither source execution details nor repair authority.
      refused_ids = Variant.joins(:turn, :model_invocation).where(public_id: variant_ids,
        turns: { conversation_id: @conversation.id, kind: "direct_reply" },
        model_invocations: { failure_reason_key: Conversation::COST_LIMIT_REACHED }).pluck(:public_id)
      Page.new(turns: turns, runs: runs, cost_refused_variant_ids: refused_ids,
        before_position: before, after_position: after,
        has_older: before && timeline.entries(surface: :timeline, before_position: before, limit: 1).any?,
        has_newer: after && timeline.entries(surface: :timeline, after_position: after, limit: 1).any?)
    end

    # An exact candidate remains exact after regeneration or activation. The
    # effective timeline owns concealment; a fork never gains its source Run.
    def variant(turn_public_id:, variant_public_id:)
      entry, variant = reachable_variant(turn_public_id, variant_public_id)
      bodies = ContentBody.preload_for_render(variant.content_bodies.where(role: %w[content prompt])).index_by(&:role)
      run = Run.visible_to(@user).find_by(variant_id: variant.id)
      loop = TurnProjection.loop_block(variant) if run
      projected = TurnProjection.variant(variant, body: bodies["content"], prompt: bodies["prompt"],
        active: variant.id == entry.turn.active_variant_id, loop: loop)
      source_readable = entry.turn.conversation_id == @conversation.id ||
        Conversation.visible_to(@user).exists?(id: entry.turn.conversation_id)
      execution_readable = source_readable && (variant.source != "run" || run.present?)
      cost_refused = entry.turn.conversation_id == @conversation.id && entry.turn.kind == "direct_reply" &&
        variant.source != "run" && variant.model_invocation&.failure_reason_key == Conversation::COST_LIMIT_REACHED
      VariantRead.new(entry: entry, variant: projected, run: run,
        variant_record: execution_readable ? variant : nil, cost_refused: cost_refused)
    end

    def field(turn_public_id:, variant_public_id:, field:, location: nil, after: nil)
      entry, variant = reachable_variant(turn_public_id, variant_public_id)
      body = variant.content_bodies.where.not(sealed_at: nil).find_by(role: field)
      History::FieldRead.call(body: body, field: field, location: location, after: after).merge(
        conversation_public_id: @conversation.public_id, turn_public_id: entry.turn.public_id,
        variant_public_id: variant.public_id, field: field, inherited: entry.inherited)
    end

    private

      def reachable_variant(turn_public_id, variant_public_id)
        entry = @conversation.timeline.entry(public_id: turn_public_id)
        raise ActiveRecord::RecordNotFound unless entry

        [entry, entry.turn.variants.live.preload(:origin_variant).find_by!(public_id: variant_public_id)]
      end
  end
end
