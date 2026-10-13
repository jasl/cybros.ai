module Conversations
  class ContextAssembly
    # THE PREFACE: what a reply turn's request placed between `history` and
    # its input — the caller's positioned lead and tail, the template's own
    # post-history inline text as the macros rendered it, memory or the
    # skills catalog when a template put them there — sealed on the turn's
    # variant by the code that assembled that request, one entry per
    # segment in layout order with the template BLOCK it came from, and
    # replayed IN PLACE by later history for the answerer's own turns. So
    # the next turn's request is the earlier one whole plus its own tail: a
    # per-turn text re-rendered, or dropped, by the next turn would edit the
    # prefix every provider cache and every signed thinking block is bound
    # to. Written once per seed path from what was sent, never re-rendered;
    # the words that opened the turn stay its `prompt`. A lead the window
    # already carried is sealed as CARRIED — the lead the turn relied on,
    # never laid and never replayed — so a re-ask whose own window no
    # longer holds the carrier lays it (ContextAssembly.assemble).
    module Preface
      ROLE = "preface".freeze
      # The block a caller's positioned lead renders from: laid once while
      # the window carries an identical one (ContextAssembly.assemble).
      LEAD = "lead".freeze

      # One segment and the template block key it rendered from — nil on a
      # sealed entry that names none — and whether it was a carried lead
      # the request relied on rather than laid.
      Laid = Data.define(:block, :segment, :carried) do
        def initialize(block:, segment:, carried: false) = super
      end

      module_function

      # Nothing between history and the input seals nothing: an absent body
      # IS the empty preface.
      def seal(variant, laid)
        return nil if laid.empty?

        entries = laid.map do |entry|
          message = Nexus::TextInputMessage.new(role: entry.segment.role, parts: entry.segment.parts)
          Nexus::InputEntries.for(message).sole.merge({ "block" => entry.block, "carried" => (true if entry.carried) }.compact)
        end
        result = ContentBodies::Replace.call(owner: variant, role: ROLE, entries: entries, seal: true)
        # A slice of a request the same bounds already admitted.
        raise ArgumentError, "the turn's preface could not be kept: #{result.refusal}" unless result.accepted?

        result.body
      end

      # The sealed run back as it was sealed, carried leads included; none
      # for a turn that placed nothing there.
      def laid(body)
        return [] if body.nil?

        body.entry_payloads.map do |payload|
          message = Nexus::TextInputMessage.from_h(payload)
          Laid.new(block: payload["block"], segment: Segment.plain(message.role, nil, parts: message.parts),
            carried: payload["carried"] == true)
        end
      end

      # What the turn's request carried there, as later history replays it.
      def segments(body) = laid(body).reject(&:carried).map(&:segment)

      # The lead the turn LAID, as `[role, text]` pairs — what a later lead
      # is compared with, role and text byte for byte; a carried one is in
      # no prefix, so it carries nothing forward.
      def lead_pairs(body) = pairs(laid(body).select { |entry| entry.block == LEAD && !entry.carried })

      def pairs(entries) = entries.map { |entry| [entry.segment.role, entry.segment.text] }
    end
  end
end
