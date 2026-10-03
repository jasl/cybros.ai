module Conversations
  class ContextAssembly
    # One assembled turn on its way to the wire; after the replay ladder,
    # `reasoning_parts` stay in-message and `reasoning_items` are
    # role-less items before the message. A loop-backed round's placed
    # tail — `trailing`, the `[ordinal, element]` pairs RoundReplay's walk
    # placed (calls, a phased round's messages, and the reasoning items the
    # ladder lands at or after `first_slot`) — and its results follow the
    # message, already in their wire shape; `call_items` are the calls
    # alone, the ones a signature substitutes.
    #
    # `parts` is the turn's ORDERED part tail: text parts and
    # native attachments in the positions the person wrote them, so two
    # merged user segments keep "the diagram below" beside its diagram —
    # a text member plus a trailing attachment list would reorder them on
    # every merge (a failed turn's seed then the new input, regenerate
    # siblings, a landed steer beside the seed). `text` is a reading of the
    # parts, never a second member.
    #
    # `phase` is a plain reply's label from its wire (its trace's last
    # message's), resent with the trace's origin; a round's labelled
    # messages ride `trailing` instead.
    #
    # `alone` marks a message the loop lane SENT ON ITS OWN — a round's
    # delivered material and the steers it read, each its own user message
    # in that round's sealed request: the assembly never merges it with a
    # neighbour, so later history carries it as that request did, on every
    # wire (a Responses or chat lane sends one item per message; Anthropic's
    # lowering merges same-role neighbours for both alike).
    #
    # `replay_tokens` is what the reasoning the ladder landed on this segment
    # costs (`Replayed`): the provider's captured count, or the landed texts
    # — 0 on every segment that carries none. Reasoning is history, priced
    # with its turn in the one fit.
    Segment = Data.define(:role, :parts, :trace, :reasoning_parts, :reasoning_items,
      :call_items, :result_items, :trailing, :first_slot, :phase, :alone, :replay_tokens) do
      def self.plain(role, text, trace: nil, parts: nil, phase: nil, alone: false)
        new(role: role, parts: parts || text_parts(text), trace: trace,
            reasoning_parts: [], reasoning_items: [], call_items: [], result_items: [],
            trailing: [], first_slot: nil, phase: phase, alone: alone, replay_tokens: 0)
      end

      def self.round(role, text, calls:, trailing:, first_slot:, results:, trace: nil)
        new(role: role, parts: text_parts(text), trace: trace,
            reasoning_parts: [], reasoning_items: [], call_items: calls, result_items: results,
            trailing: trailing, first_slot: first_slot, phase: nil, alone: false, replay_tokens: 0)
      end

      def self.text_part(text) = Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: text)
      def self.text_parts(text) = text.nil? ? [] : [text_part(text)]

      def trailing_items? = trailing.any? || result_items.any?

      def texts = parts.filter_map { |part| part.text if part.type == Nexus::InputParts::TEXT }
      def attachments = parts.select { |part| part.type == Nexus::InputParts::UPLOAD }

      # The words, as one string: adjacent texts read as merged texts do.
      def text = texts.reject(&:blank?).join("\n\n")
      def words? = texts.any?(&:present?)
      # Nothing to say and nothing to show.
      def blank? = !words? && attachments.empty?

      # Replayed reasoning rides this segment, in-message or as items: such a
      # segment never merges with a neighbour (the facade's merge rule).
      def reasoning? = reasoning_parts.any? || reasoning_items.any?

      # Everything the wire will carry as countable text: the message and
      # the items behind it, so a tool-heavy round is priced as sent. A
      # reasoning item the ladder placed in the tail is priced once, by
      # `replay_tokens`.
      def priced_texts
        placed = trailing.map(&:last).reject { |element| element in Nexus::ReasoningInputItem }
        texts + Nexus::ModelRequestInput.text_segments(placed + result_items)
      end

      # The segment as the wire carries it, in the loop lane's order: leading
      # items, the message, the placed tail, the results.
      def elements = reasoning_items + Array(message) + trailing.map(&:last) + result_items

      # What the request seals for it — the byte half of the fit. Unstorable
      # text is not "too large": the seal answers it with its own refusal.
      def bytes
        ContentBodies::Measure.call(Nexus::InputEntries.for(elements)).bytes
      rescue Nexus::CanonicalJson::UnsupportedText, Nexus::CanonicalJson::UnsupportedNumber
        0
      end

      # A round that only called tools has no message of its own: its items
      # stand alone, as the continuation sends them. The parts ride in order
      # — a picture with no words is still a message; a blank text part is
      # nothing to send. A labelled reply carries its phase with the origin
      # that licenses it.
      def message
        return nil if blank? && reasoning_parts.empty?

        kept = parts.filter_map do |part|
          case part.type
          when Nexus::InputParts::UPLOAD then part.to_part
          else part unless part.text.blank?
          end
        end
        Nexus::TextInputMessage.new(role: role, parts: reasoning_parts + kept,
          phase: phase, native_origin: (trace.native_origin if phase))
      end
    end

    # A native attachment in the tail: the bound row, kept for the placed
    # set the seal binds and for the fill cost; its wire form is the
    # OneShot's upload part. A picture the row cannot take never becomes
    # one of these — it is a text part holding the index line.
    Segment::Attachment = Data.define(:upload) do
      def type = Nexus::InputParts::UPLOAD
      def to_part = Nexus::UploadInputPart.new(type: type, upload_public_id: upload.public_id)
    end
  end
end
