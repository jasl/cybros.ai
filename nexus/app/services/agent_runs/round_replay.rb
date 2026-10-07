module AgentRuns
  # ONE renderer of what a round said: its answer with the reasoning the
  # ladder replays, the calls it made in the order the model emitted them,
  # and the fan's results paired through Pairing. The continuation reads
  # it for its mainline source; ChatHistory reads it for every mainline round of
  # a loop-backed turn. Two readers, one spelling.
  class RoundReplay
    # The round in wire order (Placement's walk): the native items that
    # LEAD, role-less; the HOST message — the body's words with the
    # reasoning parts or fence the ladder hands it, nil when the round has
    # nothing to host; the TRAILING `[ordinal, element]` pairs — calls,
    # later reasoning items and a phased round's messages, each at its
    # place; the results; and, after the last result, the round's ONE
    # picture-only message when a result captured a picture. `call_items`
    # are the calls alone, in the order they were placed — their own
    # member, never recovered from `trailing`. `picture_uploads` are the
    # paired results' bound rows in occurrence order: the loop lane reads
    # their `picture` message, while conversation history places and prices
    # them with the round. Both lanes seal only the rows they place.
    Round = Data.define(:leading, :message, :trailing, :call_items, :result_items, :picture_uploads, :first_slot) do
      # What the round itself SAID — its output as the provider counted it:
      # the reasoning it replays, its message, its calls and labelled words.
      def said = leading + Array(message) + trailing.map(&:last)
      def elements = said + result_items + Array(picture)
      def empty? = leading.empty? && message.nil? && trailing.empty? && result_items.empty?

      def picture
        return nil if picture_uploads.empty?

        Nexus::TextInputMessage.new(role: "user", parts: picture_uploads.map do |upload|
          Nexus::UploadInputPart.new(type: Nexus::InputParts::UPLOAD, upload_public_id: upload.public_id)
        end)
      end

      # The host message's own words, apart from any replayed reasoning
      # parts — nil on a phased round, whose words ride `trailing`.
      def text
        message&.parts&.find { |part| part.type == Nexus::InputParts::TEXT }&.text
      end
    end

    class << self
      # `tips_by_call_key` are the branch tips a reader has in hand, by the
      # `task` call that made each: that call's paired result is rendered
      # as the tip's envelope, never its own "started" text. `cleared`
      # renders every result as the prune placeholder.
      def call(node, fan_by_call_id:, replay: nil, tips_by_call_key: {}, cleared: false, reference: false)
        new(node, fan_by_call_id: fan_by_call_id, replay: replay,
          tips_by_call_key: tips_by_call_key, cleared: cleared, reference: reference).call
      end

      # Compaction replaced the answer, but this fan still needs its first
      # read, including the native replay its wire requires. The same
      # renderer suppresses only the old words. A history reader may hand
      # in its batched trace to place the calls before its own replay pass.
      def pairs(node, fan_by_call_id:, tips_by_call_key: {}, replay: nil, trace: nil, cleared: false)
        new(node, fan_by_call_id: fan_by_call_id, replay: replay, tips_by_call_key: tips_by_call_key, cleared: cleared)
          .call(only_pairs: true, captured_trace: trace)
      end

      def native_replay?(replay)
        replay&.replay? && replay.target.capability.format != "none" && replay.target.reasoning_enabled != false
      end

      # Each round's OWN fan by call id — the tool tasks it expanded, so a
      # call id a later round reuses never reaches back for an older
      # result. One read for a whole window of rounds.
      def fans_of(rounds)
        return {} if rounds.empty?

        AgentRunEdge.where(from_node_id: rounds.map(&:id)).includes(:to_node)
          .group_by(&:from_node_id)
          .transform_values do |edges|
            edges.map(&:to_node)
              .select { |tool| tool.tool_call? && tool.tool_call_id.present? }
              .index_by(&:tool_call_id)
          end
      end

      # History replays many rounds at once; the same associations serve a
      # single continuation without loading the rest of its loop. The trace
      # loads whatever the replay mode: it is the round's ORDER and its
      # messages' labels, read whenever the round renders; the replay mode
      # gates only the ladder.
      def preload(rounds, calls:, tips_by_call_key: {})
        ActiveRecord::Associations::Preloader.new(
          records: rounds,
          associations: {
            tool_calls_body: { content_body_entries: :content_fragment },
            reasoning_trace_body: { content_body_entries: :content_fragment },
          }
        ).call
        nodes = rounds + result_nodes(calls, tips_by_call_key: tips_by_call_key)
        ActiveRecord::Associations::Preloader.new(
          records: nodes,
          associations: { output_body: { content_uploads: { file_attachment: :blob } } }
        ).call
        # Captured pictures need the ordered result blocks even when the
        # output already has a text projection. Batch them across history.
        ActiveRecord::Associations::Preloader.new(
          records: nodes.filter_map(&:output_body).select do |body|
            body.readable_text.nil? || Pairing.pictures(body).any?
          end,
          associations: { content_body_entries: :content_fragment }
        ).call
      end

      # Body readers bind and preload the same nodes whose results Pairing
      # renders. A wrapper's acknowledgement owns none of its child's captures.
      def result_nodes(calls, tips_by_call_key:)
        calls.map { |call| Pairing.result_node(call, tips_by_call_key[[call.agent_run_id, call.node_key]]) }
      end
    end

    # `replay` is the assembled lane's Replay value (mode + resolved
    # target); nil renders the round without reasoning, which is what a
    # reader outside the loop's own lane means.
    def initialize(node, fan_by_call_id:, replay:, tips_by_call_key: {}, cleared: false, reference: false)
      @node = node
      @fan_by_call_id = fan_by_call_id
      @replay = replay
      @tips_by_call_key = tips_by_call_key
      @cleared = cleared
      @reference = reference
    end

    def call(only_pairs: false, captured_trace: nil)
      replay_trace = !only_pairs || self.class.native_replay?(@replay)
      decision = replay_decision if replay_trace
      placed_trace = captured_trace || (trace if replay_trace)
      paired = Pairing.call(calls: round_calls, nodes_by_call_id: @fan_by_call_id,
        tips_by_call_key: @tips_by_call_key, cleared: @cleared, reference: @reference)
      placed = Placement.call(trace: placed_trace, natives: replayed_items(decision),
        calls: tool_call_items(decision), text: (body_text unless only_pairs), messages: !only_pairs)
      Round.new(
        leading: placed.leading,
        message: host_message(decision, phased: only_pairs || placed.phased),
        trailing: placed.trailing,
        call_items: placed.call_items,
        result_items: paired.items,
        picture_uploads: paired.picture_uploads,
        first_slot: placed.first_slot
      )
    end

    private

      def body_text = @node.output_body&.effective_text

      # Replay lands two ways because the wires differ: Responses and
      # DeepSeek carry reasoning as items (Placement puts each where it was
      # thought), Anthropic, Gemini and the chat field as parts inside this
      # message, leading the assistant's own content. A phased round's words
      # ride their own messages, so the host holds only what the ladder
      # handed it — a parts-only message, or none.
      def host_message(decision, phased:)
        text = phased ? nil : body_text
        parts = replayed_parts(decision)
        return nil if text.blank? && parts.empty?

        body = text.present? ?
          [Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: text)] : []
        Nexus::TextInputMessage.new(role: "assistant", parts: parts + body)
      end

      # A call may carry the signature the provider bound to the thinking
      # that produced it (Gemini's thoughtSignature rides the functionCall part).
      def tool_call_items(decision)
        payloads = decision&.call_payloads || {}
        origin = trace.native_origin if payloads.any?
        round_calls.map do |entry|
          payload = payloads[entry["id"].to_s]
          item = Nexus::ToolCallInputItem.new(
            type: "tool_call_item",
            payload: {
              "type" => "function_call",
              "call_id" => entry["id"],
              "name" => entry["name"],
              "arguments" => entry["arguments"],
            }.compact
          )
          payload ? item.with_native_payload(payload, origin: origin) : item
        end
      end

      # The round's calls, in the order the model emitted them — the stored
      # envelope's own order, which the fan and this splice share.
      def round_calls
        @round_calls ||= begin
          envelope = @node.tool_calls_body
            &.content_body_entries&.first&.content_fragment&.payload
          Array(envelope && envelope["items"])
        end
      end

      # The native rung needs the ORIGIN's captured trace and the TARGET's
      # capability; the ladder decides and never raises. A dropped decision
      # simply contributes nothing — replay is optional material. The walk
      # reads the same trace for the round's order, replaying or not.
      def trace_envelope
        return @trace_envelope if defined?(@trace_envelope)

        @trace_envelope = @node.reasoning_trace_body
          &.content_body_entries&.first&.content_fragment&.payload
      end

      def trace
        return @trace if defined?(@trace)

        @trace = trace_envelope && ModelReasoning::Trace.new(envelope: trace_envelope)
      end

      # One decision per rendering — the ladder never raises, and a
      # dropped one simply contributes nothing.
      def replay_decision
        return @replay_decision if defined?(@replay_decision)

        @replay_decision =
          if @replay.nil? || !@replay.replay? || trace_envelope.nil?
            nil
          else
            ModelReasoning::ReplayLadder.call(trace: trace, target: @replay.target)
          end
      end

      # Each replayed item beside the trace ordinal it came from, for the walk.
      def replayed_items(decision)
        return [] unless decision&.kind == :native_item

        origin = trace.native_origin
        decision.ordinals.zip(decision.payloads).map do |ordinal, item|
          [ordinal, Nexus::ReasoningInputItem.new(type: "reasoning_item", payload: item, native_origin: origin)]
        end
      end

      def replayed_parts(decision)
        return [] unless decision&.kind == :native_parts

        origin = trace.native_origin
        decision.payloads.map do |payload|
          Nexus::ReasoningInputPart.new(
            type: Nexus::InputParts::REASONING, payload: payload,
            native_origin: origin
          )
        end
      end
  end
end
