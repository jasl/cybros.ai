module Runs
  class RoundReplay
    # THE ONE WALK over a round's traced output items, by ordinal: the
    # order is decided here, once, and both lanes consume it — the loop
    # lane's continuation and the conversation lane's history, which lands
    # its own budgeted reasoning into this placement through `split` and
    # `merge`, the same boundary rule.
    #
    # `first_slot` is the smallest marker ordinal (a message or a call).
    # Replayed native items before it LEAD, role-less, ahead of the round's
    # host message — today's shape; the rest TRAIL at their ordinals beside
    # the calls, so a reasoning item the model thought between two calls
    # stays before the call it produced. A call the trace did not mark (a
    # trace-less round, an older envelope) trails after every ordinal, in
    # envelope order.
    #
    # A PHASED round — its wire labelled the messages it produced — replays
    # one message per run of adjacent message markers of equal phase, each
    # at its run's first ordinal: the wire asserted that the round holds
    # several messages and where each stands. A round whose markers carry
    # no phase keeps the body's one message ahead of its calls (the host),
    # the bytes every lane already caches.
    module Placement
      Placed = Data.define(:leading, :trailing, :call_items, :first_slot, :phased)

      module_function

      # `trace` is the round's ModelReasoning::Trace, nil without one (no
      # markers, then); `natives` the replayed items as `[ordinal, element]`
      # pairs; `calls` the round's call items in envelope order; `text` the
      # body's words, which a round of ONE message reads (a split answer
      # stores each message's own).
      def call(trace:, natives:, calls:, text:, messages: true, message_payloads: {})
        trace ||= ModelReasoning::Trace.new(envelope: {})
        first_slot = trace.markers.map { |marker| marker.fetch("ordinal") }.min
        leading, later = split(natives, first_slot)
        placed_calls = place_calls(trace, calls)
        blocks = messages && trace.placed_message_blocks?
        phased = blocks || (messages && trace.message_markers.any? { |marker| marker["phase"] })
        placed_messages = if blocks
          block_messages(trace, text, message_payloads)
        elsif phased
          run_messages(trace, text)
        else
          []
        end
        Placed.new(
          leading: leading,
          trailing: merge(placed_calls, placed_messages, later),
          call_items: placed_calls.map(&:last),
          first_slot: first_slot,
          phased: phased
        )
      end

      # THE BOUNDARY RULE: a native item before the round's first marker
      # leads (every one of them when the round has none); the rest trail.
      # Answers the leading elements and the trailing `[ordinal, element]`
      # pairs.
      def split(pairs, first_slot)
        leading, later = pairs.partition { |ordinal, _| first_slot.nil? || ordinal < first_slot }
        [leading.map(&:last), later]
      end

      # Placed pairs joined into one tail in ordinal order — unique by
      # construction (trace ordinals, then synthetic ones past the trace).
      def merge(*tails) = tails.flatten(1).sort_by(&:first)

      # Preserve each text block's position among thinking and tool calls.
      # A Gemini block may also carry signed Parts within that position.
      def block_messages(trace, text, message_payloads = {})
        markers = trace.message_markers
        ordinary = markers.map do |marker|
          parts = marker.dig("provider_payload", "parts")
          parts ? parts.map { |part| part["text"] }.join : (markers.one? ? text.to_s : marker["text"].to_s)
        end
        # An edited or compacted answer owns its current words. Never
        # resurrect the original signed text in their place.
        if ordinary.join != text.to_s
          return [] if text.blank?

          part = Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: text)
          return [[markers.first.fetch("ordinal"), Nexus::TextInputMessage.new(role: "assistant", parts: [part], native_origin: trace.claude_origin)]]
        end

        markers.zip(ordinary).filter_map do |marker, words|
          ordinal = marker.fetch("ordinal")
          native = message_payloads[ordinal]
          parts = if native
            native.filter_map do |part|
              text_part(part.fetch("text", ""), part["thoughtSignature"], trace)
            end
          else
            next if words.empty?

            [text_part(words, nil, trace)]
          end
          [ordinal, Nexus::TextInputMessage.new(role: "assistant", parts: parts, native_origin: trace.claude_origin)]
        end
      end

      def text_part(text, signature, trace)
        return if text.empty? && !signature

        # A whitespace-only native fragment is significant between words.
        # Ordinary visible text keeps the same durable shape on every wire.
        origin = trace.native_origin if signature || text.blank?
        Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: text,
          thought_signature: signature, native_origin: origin)
      end

      # Marked calls at their markers' ordinals, the rest past the trace.
      def place_calls(trace, calls)
        ordinals = trace.call_markers.to_h { |marker| [marker["item_id"], marker.fetch("ordinal")] }
        past = trace.items.map { |item| item.fetch("ordinal") }.max.to_i + 1
        marked, unmarked = calls.partition { |call| ordinals.key?(call.payload.fetch("call_id")) }
        marked.map { |call| [ordinals.fetch(call.payload.fetch("call_id")), call] }.sort_by(&:first) +
          unmarked.each_with_index.map { |call, index| [past + index, call] }
      end

      # A run ends at any other item — a reasoning item, a call, so the next
      # message's ordinal is not the next one — or at a phase change. The
      # single message's words are the body's; a split answer's run reads
      # only its markers' own, so a message that said nothing is blank, never
      # the whole answer again. A blank run is never replayed: the wire
      # rejects an empty message item. The phase's origin rides only beside
      # a phase.
      def run_messages(trace, text)
        single = trace.message_markers.one?
        trace.message_markers
          .slice_when do |before, after|
            after.fetch("ordinal") != before.fetch("ordinal") + 1 || after["phase"] != before["phase"]
          end
          .filter_map do |run|
            words = single ? text.to_s : run.filter_map { |marker| marker["text"] }.join
            next if words.blank?

            phase = run.first["phase"]
            [run.first.fetch("ordinal"),
             Nexus::TextInputMessage.new(role: "assistant", phase: phase, native_origin: (trace.native_origin if phase),
               parts: [Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: words)])]
          end
      end
    end
  end
end
