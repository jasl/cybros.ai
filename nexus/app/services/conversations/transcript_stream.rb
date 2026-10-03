module Conversations
  # ONE TRANSCRIPT STREAM OVER THE HOST: deltas while a reply or a round
  # runs, the settled snapshot when a turn or a task terminalizes, on
  # `…:<host>:transcript` — a conversation's for a direct reply and for a
  # loop-backed round (through the seam), a standalone loop's own. One
  # vocabulary, the loop lane adding its correlation keys. Nothing here is
  # durable — the rows are the truth and REST the recovery path.
  module TranscriptStream
    STEP_KEY = AgentLoops::ApplyStepResult::KEY_PATTERN
    # THE FEED'S VOCABULARY, in one place: the deltas the sink publishes
    # while a reply or a round runs, the reset, and the three settled
    # snapshots. The contract pack renders it from here, and the progress
    # feed's frame types are pinned disjoint from it by reference.
    ITEM_TYPES = %w[
      text_delta reasoning_delta tool_call_started tool_call_arguments_delta stream_reset turn round call
    ].freeze

    # WHERE AN INVOCATION'S DELTAS GO, resolved once: the host whose stream
    # carries them, the correlation keys every item rides, and whether the
    # hidden gate silences it — the TURN's visibility or concealment on a conversation
    # host, the task's `transcript_visibility` on both. `node` is the loop
    # step the Source was resolved from (nil for a direct reply), KEPT so
    # the sink that holds a Source can narrate the round's own facts
    # (`ProgressStream.round_started`) without a second lookup.
    Source = Data.define(:host, :keys, :hidden, :node) do
      def initialize(node: nil, **) = super

      # The loop step FIRST: its invocation carries `agent_loop_id` and no
      # `conversation_id`, so the host is the loop's, never a column's.
      def self.for(model_invocation)
        node = TranscriptStream.node_for(model_invocation)
        return TranscriptStream.task_source(node) if node

        variant = ConversationTurnVariant.find_by(model_invocation_id: model_invocation.id)
        variant && TranscriptStream.reply_source(variant)
      end
    end

    module_function

    # Publishing and channel subscriptions share the same stream names.
    def stream_name(host)
      Nexus::RealtimeStreams.resource(host.model_name.singular, host.public_id, "transcript")
    end

    # The sink holds an invocation and needs the task it belongs to; the
    # generation-keyed creation key is where that link already lives.
    def node_for(model_invocation)
      return nil if model_invocation.agent_loop_id.nil?

      match = STEP_KEY.match(model_invocation.internal_creation_key.to_s)
      return nil if match.nil?

      AgentLoopNode.find_by(id: match[1])
    end

    # A task's source: the loop's host, `agent_loop_public_id` + `task_key`
    # on both hosts, and the turn keys through the seam on a conversation.
    # The turn is read only where one exists (the seam's column says so):
    # a standalone loop's Source costs the loop object nothing past its
    # host, which matters at a wide fan where every row resolves one.
    def task_source(node)
      agent_loop = node.agent_loop
      turn = agent_loop.standalone? ? nil : agent_loop.conversation_turn
      keys = { agent_loop_public_id: agent_loop.public_id, task_key: node.node_key }
      if turn
        keys = keys.merge(turn_public_id: turn.public_id,
          variant_public_id: agent_loop.conversation_turn_variant.public_id)
      end
      Source.new(host: agent_loop.host, keys: keys, node: node,
        hidden: node.transcript_visibility == "hidden" || turn&.visibility == "hidden" || turn&.deleted?)
    end

    # A direct reply's source: its variant's turn, on the conversation.
    def reply_source(variant)
      turn = variant.conversation_turn
      Source.new(
        host: turn.conversation,
        keys: { turn_public_id: turn.public_id, variant_public_id: variant.public_id },
        hidden: turn.visibility == "hidden"
      )
    end

    # The delta half owes the same visibility gate as the snapshot and the
    # window, or the feed carries a conversation no reader can reconcile.
    def delta(source:, type:, payload:)
      return if source.hidden

      publish(source.host, { type: type }.merge(source.keys).merge(payload))
    end

    # After commit, the settled turn publishes the row a reader would have
    # seen under the deltas' turn id: completion wins as an event, not a
    # client rule. A conversation host only — a loop host has no turn row.
    def settled_turn(turn, variant:, agent_loop: nil)
      return unless snapshotable_turn?(turn)

      conversation = turn.conversation
      # The settling execution owns the frame, even when a canceled
      # regeneration leaves an older completed variant in the snapshot.
      keys = { turn_public_id: turn.public_id, variant_public_id: variant.public_id }
      keys[:agent_loop_public_id] = agent_loop.public_id if agent_loop
      # After commit, not eagerly: the caller holds the conversation row,
      # and a rolled-back transition builds nothing.
      ApplicationRecord.current_transaction.after_commit do
        snapshot = TurnProjection.turn_snapshot(turn)
        # The top-level keys match the execution's deltas; the nested
        # snapshot remains the turn a paginated read would render.
        publish(conversation, { type: "turn", turn: snapshot }.merge(keys))
      end
    end

    # A settled task's `round|call` snapshot on its HOST's stream, under the
    # keys its deltas carried. Built after commit, not eagerly: the status
    # funnel is reached hundreds of times per pass, and a rolled-back
    # transition builds nothing.
    def settled_task(node)
      return unless snapshotable_task?(node)

      ApplicationRecord.current_transaction.after_commit do
        source = task_source(node)
        publish(source.host, snapshot_item(node).merge(source.keys)) unless source.hidden
      end
    end

    def snapshotable_turn?(turn)
      turn.terminal? && turn.visibility != "hidden" && turn.deleted_at.nil?
    end

    # A round or a call renders; an await and a barrier are nobody's row.
    def snapshotable_task?(node)
      node.terminal? && node.transcript_visibility != "hidden" && (node.round? || node.tool_call?)
    end

    def snapshot_item(node)
      if node.round?
        { type: "round", round: AgentLoops::Transcript.round_snapshot(node) }
      else
        { type: "call", call: AgentLoops::Transcript.call_snapshot(node) }
      end
    end

    def publish(host, event)
      ActionCable.server.broadcast(stream_name(host), { event: event })
    rescue StandardError => error
      # The cable is latency sugar and the rows are the truth: a publish
      # failure must never fail the work it was narrating.
      Rails.error.report(error, handled: true, context: {
        event: "transcript_publish_failed",
        host: "#{host.model_name.singular}:#{host.public_id}",
      })
    end
  end
end
