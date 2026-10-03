module AgentLoops
  # The one status write for both rows of this plane, so the write and its
  # narration are the same call (a code-style guard keeps them that way);
  # the event is buffered to the end of the transaction (Narration).
  class Transition
    class << self
      def agent_loop(agent_loop, **attributes)
        agent_loop.update!(**attributes)
        release_steers(agent_loop) if attributes.key?(:status) && agent_loop.terminal?
        AgentLoop::Narration.record(
          agent_loop,
          loop_items(agent_loop, announced: attributes.key?(:attention_reason))
        )
        agent_loop
      end

      # `narration` rides the status item beside the row's facts — the
      # settle's `resolved_by` (kind recorded, no column) — never a column
      # the write would need. It ADDS to the status item and never
      # suppresses one; `narrate: false` is the one write that carries its
      # own word instead (the handoff's re-address narrates
      # `task_readdressed` alone — a same-status `task_status` beside it
      # would tell a follower nothing it did not know and cost it a
      # spurious redraw). A status write still goes through this funnel
      # (the code-style guard), so the choice is explicit at the one site
      # that makes it.
      def node(node, narration: nil, narrate: true, **attributes)
        node.update!(**attributes)
        narrate_tasks(node.agent_loop, [node], narration) if narrate
        # A task that just settled publishes the transcript row a reader
        # would have seen, on its HOST's stream, so a subscriber can
        # render without ever calling REST. Non-durable, after commit,
        # failure-isolated.
        Conversations::TranscriptStream.settled_task(node)
        # A tool row dispatched, held or claimed is the kernel's own
        # `step_started` / `step_claimed` on the host's `progress` feed —
        # decided from THIS write's `saved_changes` now, published after
        # commit; a frame never becomes a row.
        Conversations::ProgressStream.transition(node)
        if node.delegation? && %w[canceled skipped].include?(attributes[:status])
          Spawn::RelayJob.perform_later
        end
        node
      end

      # Row-by-row rather than `update_all`: a saved record is what
      # triggers the narration flush.
      def nodes(scope, **attributes)
        scope.to_a.map { |node| node(node, **attributes) }
      end

      # Birth narration: a follower reading only the stream learns about
      # newly authored tasks here, since the append receipt is the AUTHOR's
      # answer and nobody else sees it.
      def created(agent_loop, nodes)
        narrate_tasks(agent_loop, nodes)
      end

      # A splice grew a queued head's sources — a branch root, then each
      # branch round, forwarded onto the round that waits. No status
      # moves, so this is the one word a follower gets that `after`
      # changed; without it, its derived `waiting_on` goes empty the
      # moment the `task` call settles.
      def spliced(agent_loop, heads)
        narrate_tasks(agent_loop, heads)
      end

      # A model round's product, task-grained: what the step answered and
      # what it cost. Both ride one append so a follower sees them together.
      def round(node, invocation)
        record = UsageRecord.for_latest_attempt(invocation)
        items = [{ type: "round_result", payload: round_payload(node, invocation, record) }]
        usage = usage_payload(node, record)
        items << { type: "usage", payload: usage } if usage

        AgentLoop::Narration.record(node.agent_loop, items)
      end

      # Bounded because the payload column is and the task count is not:
      # an oversized item would roll back the very hold it announces.
      BLOCKED_KEYS_SHOWN = 32

      # The failures an adjudicator can act on, by key, never node id — a
      # halt names them; a model's question names the question. Read by the
      # announce and by the settle that projects the hold onto the turn.
      def blocked_task_keys(agent_loop)
        blocking_nodes(agent_loop).map(&:node_key).sort.first(BLOCKED_KEYS_SHOWN)
      end

      # The current call to act, shared by the announcement and the full
      # REST read. The latter has already loaded its task rows.
      def attention_projection(agent_loop, nodes: nil)
        return if agent_loop.attention_reason.blank?

        blocked = blocking_nodes(agent_loop, nodes: nodes)
        {
          reason: agent_loop.attention_reason,
          blocked_task_keys: blocked.map(&:node_key).sort.first(BLOCKED_KEYS_SHOWN),
          blocked_task_overflow: (blocked.length - BLOCKED_KEYS_SHOWN if blocked.length > BLOCKED_KEYS_SHOWN),
        }.compact
      end

      # The newest failure holding the loop, the one a settled turn names
      # as its `error_key` — not the first key alphabetically.
      def newest_blocking_error_key(agent_loop)
        blocking_nodes(agent_loop).select(&:terminal?)
          .max_by { |node| [node.completed_at, node.id] }&.error_key
      end

      private

        # A terminal loop has no next boundary: its bound steers fall back
        # to the queue on either host, never onto the floor. A hold is not
        # terminal, so a steer typed before it stays bound. A delivered
        # reply releases at turn convergence. Old background work or a
        # stopped hold must not release a newer candidate's steers, but still
        # cancels any corrections that were pinned to its own execution.
        def release_steers(agent_loop)
          unless agent_loop.standalone?
            return if agent_loop.delivered?
            if agent_loop.conversation_turn.conversation_turn_variants.live
                .where(status: ConversationTurnVariant::ACTIVE_STATUSES)
                .where.not(id: agent_loop.conversation_turn_variant_id).exists?
              Conversations::Inputs::ReleaseSteers.call(host: agent_loop.host,
                inputs: agent_loop.steering_inputs.where(expected_steering_loop_public_id: agent_loop.public_id))
              return
            end
          end

          Conversations::Inputs::ReleaseSteers.call(
            host: agent_loop.host, inputs: agent_loop.steering_inputs
          )
        end

        def narrate_tasks(agent_loop, nodes, narration = nil)
          return if nodes.empty?

          AgentLoop::Narration.record(
            agent_loop,
            with_sources(nodes).map { |node| { type: "task_status", payload: task_payload(node, narration) } }
          )
        end

        # `after` reads each node's sources: one query for the one node a
        # transition writes, one for a whole batch (a seed, a fan) — in
        # the batch's own order, which is the stream's.
        def with_sources(nodes)
          return nodes if nodes.one?

          loaded = AgentLoopNode.where(id: nodes.map(&:id)).includes(:sources).index_by(&:id)
          nodes.map { |node| loaded.fetch(node.id) }
        end

        # Keyed on the reason, not the status: a model's question announces
        # from `running`. Only the write that touches the reason announces,
        # or every pause re-emits an identical item.
        def loop_items(agent_loop, announced: false)
          items = [{ type: "turn_status", payload: turn_status_payload(agent_loop) }]
          return items unless announced && agent_loop.attention_reason.present?

          items << {
            type: "attention_required",
            payload: attention_projection(agent_loop).stringify_keys,
          }
        end

        # Where the LOOP is, under the loop lock. A standalone loop is its
        # own host with no turn row to contradict, so its turn-shaped
        # `status` rides the same write; on a conversation host the turn's
        # row is settle's to narrate, and only the turn's id and KIND ride
        # here. The kind is the follower's: a word that queues behind a
        # between-turn summary watches the summarizer's loop narrate first,
        # and `compaction_summary` on this very item is what tells that loop
        # from the person's turn without a second read.
        def turn_status_payload(agent_loop)
          payload = {
            "agent_loop_public_id" => agent_loop.public_id,
            "loop_status" => agent_loop.status,
            "failure_reason" => agent_loop.failure_reason,
            "attention_reason" => agent_loop.attention_reason,
          }
          if agent_loop.standalone?
            shape = agent_loop.turn_shape
            payload = payload.merge("status" => shape.status,
              "failure_reason_key" => shape.failure_reason_key)
          else
            turn = agent_loop.conversation_turn
            payload = payload.merge("turn_public_id" => turn.public_id, "turn_kind" => turn.kind)
          end
          payload.compact
        end

        # The edges ride along: the settlement read looks past a
        # halt-failure to the race it may have lost, and this walk must
        # stay flat over a wide fan of them.
        def blocking_nodes(agent_loop, nodes: nil)
          nodes ||= agent_loop.agent_loop_nodes.to_a
          if agent_loop.attention_reason == EvaluateQuiescence::ASKING_REASON
            return nodes.select { |node| node.started? && node.asking? }
          end
          return nodes.select(&:held?) if agent_loop.attention_reason == EvaluateQuiescence::APPROVAL_REASON

          terminal = nodes.select(&:terminal?)
          ActiveRecord::Associations::Preloader.new(
            records: terminal, associations: { outgoing_edges: :to_node }
          ).call
          terminal.select { |node| Graph.settlement_of(node) == :pending }
        end

        # `after` is the authored list the trace row renders
        # (`AgentLoopPresenter.after`), on the item a follower holds; a root
        # carries none. `waiting_on` stays the trace's — live, derived by a
        # reader from `after` and the statuses it already has. `on_failure`
        # rides beside the stamp: an `absorb` failure carries no stamp, so a
        # follower computing the candidate rule (retry/abandon) needs the
        # policy the row was authored with. `approval` is the stage's fact,
        # one nested block, absent until a decision.
        def task_payload(node, narration = nil)
          {
            "task_key" => node.node_key,
            "kind" => node.task_kind,
            "lifetime" => node.lifetime,
            "wake" => node.wake,
            "status" => AgentLoops::TaskProjection.public_status(node.status),
            "after" => node.sources.map(&:node_key).presence,
            "on_failure" => node.on_failure,
            "error_key" => node.error_key,
            "failure_resolution" => node.failure_resolution,
            "approval" => AgentLoops::TaskProjection.approval_projection(node),
            **(narration || {}),
          }.compact
        end

        def round_payload(node, invocation, record)
          {
            "task_key" => node.node_key,
            "status" => AgentLoops::TaskProjection.public_status(node.status),
            "model" => "#{invocation.provider_id}/#{invocation.model_ref}",
            "finish_quality" => invocation.finish_quality,
            # The provider's word beside a declined finish, absent when it
            # named none.
            "refusal_category" => invocation.refusal_category,
            "error_key" => invocation.failure_reason_key,
            # What the provider answered (status, sentence, code, type — or a
            # classifier's explanation beside a declined finish), so a reader
            # of the feed can say WHY without the stored request.
            "error_detail" => invocation.failure_detail,
            # Silent truncation, narrated and never acted on: evidence
            # for a console, absent when nothing looks cut.
            "input_truncation_suspected" =>
              (true if Conversations::Compaction::LastUsage.truncation_suspected?(node, record)),
            # Normalized tool calls join here with the round driver — the
            # field is the driver's, not a placeholder to fake now.
          }.compact
        end

        # The latest attempt's receipt, never an arbitrary one: a failed
        # first try's empty numbers are not the round's cost.
        def usage_payload(node, record)
          return nil if record.nil?

          {
            "task_key" => node.node_key,
            "input_tokens" => record.input_tokens,
            "output_tokens" => record.output_tokens,
            "reasoning_tokens" => record.reasoning_tokens,
            "total_tokens" => record.total_tokens,
            # Cache reuse is a tool loop's dominant cost term; a transcript
            # that cannot show it is one nobody can tune.
            "cache_read_tokens" => record.cache_read_tokens,
            "cache_creation_tokens" => record.cache_creation_tokens,
          }.compact
        end
    end
  end
end
