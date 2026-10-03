module Conversations
  # THE ONE ADDRESS RESOLVER of the conversation verbs: what
  # `send`/`status`/`cancel` name — a child's LABEL among the sender
  # conversation's own children (the name `spawn` gave it), or any
  # conversation's public id — read through `Conversation.visible_to`, so
  # the tool plane sees exactly what the member plane shows the sender and
  # `none` reads as absence here too. The refusals, by name: an address
  # that names nothing readable (`unknown_conversation`), a side (never an
  # addressee), and — unless the verb only reads — a conversation ABOVE the
  # sender in its own subagent tree (`ancestor_conversation`: a subagent's
  # `cancel` or steer there would stop or interrupt the turn it answers
  # to). One's own conversation resolves: it is not above itself.
  class ConversationAddress
    Resolution = Data.define(:conversation, :refusal)

    def self.resolve(...) = new(...).resolve

    def initialize(sender_conversation:, sender:, address:, admit_ancestors: false)
      @sender_conversation = sender_conversation
      @sender = sender
      @address = address
      @admit_ancestors = admit_ancestors
    end

    def resolve
      target = find
      return Resolution.new(conversation: nil, refusal: :unknown_conversation) if target.nil?
      return Resolution.new(conversation: target, refusal: :side_conversation) if target.side?
      if !@admit_ancestors && SubagentTree.ancestor?(target, @sender_conversation)
        return Resolution.new(conversation: target, refusal: :ancestor_conversation)
      end

      Resolution.new(conversation: target, refusal: nil)
    end

    private

      def visible = Conversation.visible_to(@sender, workspace: @sender_conversation.workspace)

      # The id first — the wire's one truth — then the label, normalized
      # as the door normalized it; a word of neither shape is nothing.
      def find
        word = @address.to_s.strip
        return nil if word.empty?

        by_id(word) || by_label(word.downcase)
      end

      def by_id(word) = (visible.find_by(public_id: word) if ConversationInput.uuid_shaped?(word))

      def by_label(word)
        return nil unless word.match?(Conversation::SPAWN_LABEL_FORMAT)

        visible.find_by(parent_conversation_id: @sender_conversation.id, spawn_label: word)
      end
  end
end
