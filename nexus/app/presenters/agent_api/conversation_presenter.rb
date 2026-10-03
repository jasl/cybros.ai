module AgentAPI
  # Projections for the conversation plane: Basic for lists, Full for singular
  # responses, input acceptance and timeline entries. No row ids or head counter;
  # `context` is provider truth (newest succeeded usage record), never a local re-count.
  class ConversationPresenter
    LoopBlock = Conversations::TurnProjection::LoopBlock

    class << self
      def basic(conversation)
        {
          public_id: conversation.public_id,
          title: conversation.title,
          # WHO ANSWERS: the stored answering profile — one scalar off a
          # preloaded association, so the listings say it too.
          answering_user_public_id: conversation.answering_user.public_id,
          archived_at: conversation.archived_at,
          billing_subject: conversation.billing_subject_key,
          # THE PARENT FACTS: a subagent names its parent, the `spawn` call
          # that minted it and its label as ONE block — the `/children`
          # listing prints them; nil on a top-level row.
          parent: parent(conversation),
          forked_from_turn_public_id: conversation.forked_from_turn_public_id,
          forked_from_variant_public_id: conversation.forked_from_variant_public_id,
          # A SIDE CONVERSATION: a child row a UI may hide, forked at the
          # live head from the parent's last settled turn. On basic so the
          # listings say it (the working list hides sides; `?side=1`).
          side: conversation.side,
          active_turn_public_id: conversation.active_turn&.public_id,
          context_revision: conversation.context_revision,
          last_activity_at: conversation.last_activity_at,
          created_at: conversation.created_at,
          updated_at: conversation.updated_at,
        }
      end

      def full(conversation)
        basic(conversation).merge(
          metadata: conversation.metadata,
          memory_context: conversation.memory_context,
          input_queue: {
            limit: conversation.input_queue_limit,
            held: conversation.conversation_inputs.caller_authored.count,
          },
          latest_event_cursor: latest_event_cursor(conversation),
          context: context_report(conversation),
          # THE BINDING IS READABLE: where the next round's runner-kind
          # calls land, nil when unbound or reaped. Not on `basic` — the
          # listings stay lean.
          runner: ExecutorPresenter.binding(conversation.bound_runner, live_server_ids: NexusServer.live_ids),
          # THE ACCESS CARRIER: the default and the named entries. The
          # creator and the answerer are derived and never rows. Each
          # entry is self-describing — the member plane has no user
          # listing, so this is where it prints another User's
          # `display_name`. Not on `basic`; never nil.
          access: access(conversation),
        )
      end

      def input(input)
        {
          public_id: input.public_id,
          queue_position: input.queue_position,
          state: input.state,
          kind: input.kind,
          role: input.role,
          delivery_mode: input.delivery_mode,
          expected_steering_loop_public_id: input.expected_steering_loop_public_id,
          # The source kind, always present: `person` on a human's word,
          # `agent` on a peer's `send`, `task_result` on the receipt a
          # background task's answer became, `child` on a spawned
          # conversation's reply. The kernel's two drain first, wake an
          # idle conversation and are immutable to the person; the
          # sender stamp rides only the stamped rows.
          origin: input.origin,
          sender_conversation_public_id: input.sender_conversation_public_id,
          callback_result: input.callback_result,
          # WHO ANSWERS and WHO SPOKE: the addressee's id, and the author
          # as a self-describing block.
          answering_user_public_id: input.answering_user.public_id,
          speaker: Conversations::TurnProjection.actor_speaker(input.speaker_actor),
          **assembly_intent(input),
          # The turn's tool subset when the row names one; absent means the
          # declaring profile's whole declaration.
          tool_names: input.tool_names,
          # The turn's approval tightening when the row names one; absent
          # means the declaring profile's word.
          approval_mode: input.approval_mode,
          # `raw`'s system field when the row carries one.
          instructions: input.instructions,
          blocked_reason: input.blocked_reason,
          text: input.text,
          # The pictures beside the words, in part order — a fact of the
          # row whatever the answerer will read; absent when none.
          attachments: Conversations::TurnProjection.attachments(input.content_body),
          lock_version: input.lock_version,
          created_at: input.created_at,
          # THE ROW'S CLOCK: the "not before" the kernel holds on a
          # scheduled row; absent on an untimed one.
          deliver_at: input.deliver_at,
        }.compact
      end

      def turn_entries(...) = Conversations::TurnProjection.turn_entries(...)
      def turn_block(...) = Conversations::TurnProjection.turn_block(...)
      def turn_snapshot(...) = Conversations::TurnProjection.turn_snapshot(...)
      def variant(...) = Conversations::TurnProjection.variant(...)
      def loop_blocks(...) = Conversations::TurnProjection.loop_blocks(...)
      def loop_block(...) = Conversations::TurnProjection.loop_block(...)

      private

        # The call's key is the id the spawning model read back; it goes
        # nil with the spawning loop's reap while the parent's id — a
        # public-id snapshot — survives, as it does for every child.
        def parent(conversation)
          return nil unless conversation.subagent?

          {
            public_id: conversation.parent_conversation_public_id,
            spawn_node_key: conversation.spawn_node&.node_key,
            label: conversation.spawn_label,
          }
        end

        def access(conversation)
          {
            default: conversation.access_default,
            entries: conversation.conversation_access_entries.includes(:user).order(:id).map do |entry|
              { user_public_id: entry.user.public_id, handle: entry.user.handle, kind: entry.user.kind,
                display_name: entry.user.display_name, level: entry.level }
            end,
          }
        end

        # What only a host with a reply lane accepts: a loop-host row shows
        # what its door admits, never a default it would lie about.
        def assembly_intent(input)
          return {} unless input.host.hosts_turns?

          { context_mode: input.context_mode, context_options: input.context_options.presence }
        end

        def latest_event_cursor(conversation)
          sequence = conversation.conversation_event_items.maximum(:sequence)
          sequence && ConversationEventItem::ReplayCursor.encode(sequence)
        end

        # Occupancy from the last provider-reported usage record — the
        # recorded doctrine: the provider's own count of the last request is
        # the only honest answer to "how full is this conversation". ONE
        # reader with the compaction arm: a loop-backed turn's number is its
        # newest round's, which carries no conversation id.
        def context_report(conversation)
          record = Conversations::Compaction::LastUsage.for_conversation(conversation)&.record
          return nil if record.nil?

          window = window_for(record)
          used = record.total_tokens
          {
            used_tokens: used,
            input_tokens: record.input_tokens,
            output_tokens: record.output_tokens,
            # The provider's own count of the prefix it served from
            # cache; absent when it reported none — never a local count.
            cache_read_tokens: record.cache_read_tokens,
            window_tokens: window,
            used_percent: window && used ? (used * 100.0 / window).round(1) : nil,
            # A receipt names its model as one catalog key; the wire splits it
            # the way every other model block on this plane is shaped.
            as_of_model: {
              provider_id: record.provider_id,
              model_ref: Nexus::ModelRef.parse(record.catalog_model_ref).model_ref,
            },
          }.compact
        end

        def window_for(record)
          catalog = ModelSelection::Resolver.effective_provider_catalog(
            record.account, ModelCatalog.current, record.provider_id
          )
          entry = catalog.models[record.catalog_model_ref]
          return nil if entry.nil?

          limits = entry.dig("capabilities", "limits") || {}
          limits["input_tokens"] || limits["combined_input_output_tokens"]
        rescue ModelCatalog::Unavailable
          nil
        end
    end
  end
end
