module Conversations
  # The shared turn and variant projection for timeline reads and settled
  # transcript items. Loading stays batched for a page and local for a snapshot.
  module TurnProjection
    # What a loop-backed variant adds: the loop's id — the feed's
    # correlation key — and its newest MAINLINE rounds as the transcript's rows
    # without their calls. Never an edge, a join or a mainline mark: a turn
    # shows rounds, never the graph. And `runner_effects`: what the loop did to the
    # environments, derived from retained first claims by
    # `AgentRuns::RunnerEffects`, one opaque checkpoint per Runner.
    RunBlock = Data.define(:run_public_id, :rounds, :runner_effects, :model, :details_pruned_at) do
      def initialize(model: nil, details_pruned_at: nil, **) = super
    end

    class << self
      # One batched body read for the page — the funnel hands turns, this
      # attaches each entry's rendered content without a query per turn;
      # the loops behind loop-backed variants ride the same batch.
      def turn_entries(entries)
        preload_voices(entries.map(&:turn))
        active_ids = entries.filter_map { |entry| entry.turn.active_variant_id }
        candidates = ConversationTurnVariant.live.where(conversation_turn_id: entries.map { |entry| entry.turn.id })
        variants = candidates.where(id: active_ids)
          .or(candidates.where(status: ConversationTurnVariant::ACTIVE_STATUSES))
          .preload(:origin_variant).index_by(&:id)
        running = variants.values.select { |variant| !variant.terminal? && !active_ids.include?(variant.id) }
          .index_by(&:conversation_turn_id)
        variant_ids = variants.keys
        # Both roles in one read: the content the turn shows, and a reply
        # turn's seed — whose pictures the variant block names.
        bodies = ContentBody.preload_for_render(
          ContentBody.where(conversation_turn_variant_id: variant_ids, role: %w[content prompt])
        )
          .group_by(&:role)
          .transform_values { |rows| rows.index_by(&:conversation_turn_variant_id) }
        contents = bodies.fetch("content", {})
        prompts = bodies.fetch("prompt", {})
        loops = loop_blocks(variant_ids)

        entries.map do |entry|
          variant = variants[entry.turn.active_variant_id]
          pending = running[entry.turn.id]
          pending_projection = pending && variant(pending,
            body: contents[pending.id], active: false, loop: loops[pending.id], prompt: prompts[pending.id])
          turn_block(entry.turn, entry.visibility, entry.inherited,
            variant, variant && contents[variant.id], variant && loops[variant.id],
            variant && prompts[variant.id], running_variant: pending_projection)
        end
      end

      # ONE turn's wire shape, taking everything it renders as arguments —
      # the batched read above and the single-turn snapshot below both go
      # through here, so the two can never render one turn two ways.
      def turn_block(turn, visibility, inherited, variant, body, loop = nil, prompt = nil, running_variant: nil)
        {
          public_id: turn.public_id,
          input_public_id: turn.input_public_id,
          callback_sources: turn.callback_sources,
          position: turn.position,
          kind: turn.kind,
          role: turn.role,
          status: turn.status,
          visibility: visibility,
          inherited: inherited,
          reference: (true if turn.reference?),
          origin: turn.origin,
          sender_conversation_public_id: turn.sender_conversation_public_id,
          sender_run_public_id: turn.sender_run_public_id,
          sender_task_key: turn.sender_task_key,
          # WHO ANSWERED: on every kind — the addressee of a reply, the
          # conversation's answerer on a message or summary — and WHO
          # SPOKE, the voice the renderer reads: a message turn's
          # speaker, a reply turn's answerer; absent on the kernel's
          # summary, which names no principal.
          answering_user_public_id: turn.answering_user.public_id,
          speaker: turn.role == "assistant" ? speaker(turn.answering_user) : actor_speaker(turn.speaker),
          active_variant: variant && variant_block(variant, body, loop, prompt),
          # Regeneration or automatic fallback can run beside the displayed answer. Include that
          # candidate so recovery need not fetch and search the whole deck.
          # When the displayed candidate itself is running, do not repeat it.
          running_variant: running_variant,
          created_at: turn.created_at,
        }.compact
      end

      def materialization(turn, variant, agent_run = nil)
        {
          input_public_id: turn.input_public_id,
          turn_public_id: turn.public_id,
          variant_public_id: variant.public_id,
          run_public_id: agent_run&.public_id,
        }
      end

      # One settled turn in the shape a timeline page serves it, so a stream
      # consumer never reconciles two projections of one turn. A local row reads
      # its own visibility; an inherited prefix turn never terminalizes here.
      def turn_snapshot(turn)
        variant = turn.active_variant
        bodies = variant ? ContentBody.where(conversation_turn_variant_id: variant.id).index_by(&:role) : {}
        turn_block(turn, turn.visibility, false, variant, bodies["content"], variant && loop_block(variant),
          bodies["prompt"])
      end

      # The deck listing's shape — the entry projection's variant block
      # with the active flag the deck needs. `loop` is the seam's read for
      # a variant that may be loop-backed (the deck, the swipe, the view
      # state, the 202 of a regeneration); an edit sibling never is, and a
      # regeneration sibling is exactly when its origin was: a loop-backed
      # turn regenerates as a new loop behind a new candidate. Every door
      # renders the block one way: `prompt_text` and `attachments` read
      # the variant's `prompt` body when the door hands one, as the turns
      # page does.
      def variant(variant, body:, active:, loop: nil, prompt: nil)
        variant_block(variant, body, loop, prompt).merge(active: active)
      end

      # The seam's read, batched by variant id: one loop query for the
      # page, one windowed rounds query for its loops, one windowed
      # first-write query for their runner_effects, and one current-model query.
      # The current model cannot come from the visible rounds window: its
      # main-line tail may be hidden or absent from that page.
      # The signature is the invariant:
      # every door that renders a loop-backed variant — the turns page, the
      # deck, the swipe, the view state, the 202 regeneration — and the SSE
      # `turn_snapshot` render the fact one way.
      def loop_blocks(variant_ids)
        loops = AgentRun.where(conversation_turn_variant_id: variant_ids).to_a
        rounds = AgentRuns::Transcript.turn_rounds(loops)
        runner_effects = AgentRuns::RunnerEffects.first_writes(loops.map(&:id))
        models = AgentRuns::CurrentModel.for_loops(loops)
        loops.to_h do |loop|
          [loop.conversation_turn_variant_id,
           RunBlock.new(run_public_id: loop.public_id, rounds: rounds.fetch(loop.id, []),
             runner_effects: AgentRuns::RunnerEffects.fact(runner_effects[loop.id], details_pruned_at: loop.details_pruned_at),
             model: models[loop.id], details_pruned_at: loop.details_pruned_at)]
        end
      end

      def loop_block(variant) = loop_blocks([variant.id])[variant.id]

      # One principal as a turn or input names it — the access entry's
      # own four words, so a consumer reads one shape.
      def actor_speaker(actor)
        return speaker(actor.user) unless actor.kind == "ingress"

        { speaker_public_id: actor.public_id, kind: "ingress", display_name: actor.display_name }
      end

      def speaker(user)
        return nil if user.nil?

        { user_public_id: user.public_id, handle: user.handle, kind: user.kind, display_name: user.display_name }
      end

      # One descriptor per occurrence, in part order; nil when the body
      # binds none, so every existing pin stays byte-stable.
      def attachments(body)
        return nil if body.nil?

        rows = body.upload_parts
        return nil if rows.empty?

        rows.map do |upload|
          { public_id: upload.public_id, filename: upload.filename.to_s,
            content_type: upload.content_type, byte_size: upload.byte_size }
        end
      end

      private

        # The two voices a page reads per turn, loaded once for the page.
        def preload_voices(turns)
          ActiveRecord::Associations::Preloader.new(
            records: turns, associations: [{ speaker: :user }, :answering_user, :conversation]
          ).call
        end

        # `.compact` keeps the loop keys — `runner_effects` included — absent on
        # every other variant: a consumer reads them by presence.
        # `attachments` are the pictures the turn carried: a message
        # turn's content, or a reply turn's seed (`prompt`) — the row's
        # fact, whatever the wire read. `prompt_text` is the person's
        # words that OPENED a reply turn: the seed's own readable text,
        # read as `content` reads its body — absent on a message turn
        # (its `content` IS the person's words) and on a seed carrying no
        # text (a picture alone), so every existing pin stays
        # byte-stable.
        def variant_block(variant, body, loop, prompt = nil)
          model = loop&.model || variant
          {
            public_id: variant.public_id,
            source: variant.source,
            origin_variant_public_id: variant.origin_variant&.public_id,
            status: variant.status,
            model: {
              provider_id: model.provider_id,
              model_ref: model.model_ref,
              reasoning_effort: model.reasoning_effort,
              reasoning_enabled: model.reasoning_enabled,
            }.compact.presence,
            content_preview: variant.content_preview,
            content: body&.effective_text,
            prompt_text: prompt&.effective_text.presence,
            attachments: attachments(body) || attachments(prompt),
            run_public_id: loop&.run_public_id,
            rounds: loop&.rounds,
            runner_effects: loop&.runner_effects,
            details_pruned_at: loop&.details_pruned_at || variant.details_pruned_at,
          }.compact.merge(
            # The execution's frozen bindings, independent of the conversation's current setting.
            # Keep null: it names the default roots; an empty bindings list explicitly disables them.
            memory_context: variant.memory_context
          )
        end
    end
  end
end
