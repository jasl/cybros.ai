module Conversations
  class ContextAssembly
    # THE SPEAKER ENVELOPE:
    # ONE renderer for a user-side row that is not the host's own voice —
    # the bytes a model reads when someone other than its person speaks:
    #
    #   <message from="@lark" kind="agent" user="<public_id>" conversation="<sender id>">
    #   …the row's words…
    #   </message>
    #
    # Line-structured as `<task_result>` is (the mock's directive is
    # per-line; a single-line wrapper would make every peer row
    # directive-less). `user=` is the id the model can echo into `to`;
    # `conversation=` rides only a row sent from another conversation
    # (the sender stamp). Rendered at ASSEMBLY, never stored: the row keeps
    # the bare words, and a renamed handle re-renders from the row.
    #
    # WHO IS BARE (the Claude Code shape — the unlabelled voice is
    # the model's principal): a row posted directly into the host by one of
    # its OWN voices — its creator, the ANSWERER of the turn the row is
    # read for, and the Human that answerer answers to (the steward of an
    # answering profile; the human themself on a human-answered turn).
    # The answerer is the TURN's: the input's addressee on
    # the wire, the turn's own column in history — the host's default
    # everywhere but a group turn, so every 1:1 lane keeps its bytes and
    # B's turn bares B's person, not A's. Every other principal's row is
    # wrapped: another human, another agent, and every row sent FROM
    # another conversation whoever sent it (a peer's `send`, a subagent's
    # brief — the spawner's row on a copy of itself). The kernel's own rows
    # (`KERNEL_ORIGINS`) are never wrapped: their text IS the
    # `<task_result>` envelope.
    #
    # THE NARROW ESCAPER: inside any kernel envelope a body may not
    # forge or close one. Exactly four forms are spelled — `</task_result`,
    # `</message`, `<task_result ` and `<message ` — by writing their `<`
    # as `&lt;`; `&`, every other `<` and a bare `<task_result>` stay, so
    # code in a body survives. Reversible: `&lt;` before those four words
    # is the only spelling (`unescape`).
    module SpeakerEnvelope
      FORGERS = %r{<(?=/task_result|/message|task_result |message )}
      SPELLED = %r{&lt;(?=/task_result|/message|task_result |message )}
      LT = "&lt;".freeze
      CLOSE = "</message>".freeze

      module_function

      def render(author:, text:, conversation: nil)
        attributes = [
          "from=\"@#{author.handle}\"", "kind=\"#{author.kind}\"", "user=\"#{author.public_id}\"",
          ("conversation=\"#{conversation}\"" if conversation.present?),
        ].compact.join(" ")
        ["<message #{attributes}>", escape(text), CLOSE].join("\n")
      end

      def ingress(actor, text)
        return text if text.blank?

        name = ERB::Util.html_escape(actor.display_name).gsub("\n", "&#10;").gsub("\r", "&#13;")
        ["<message from=\"#{name}\" kind=\"ingress\" actor=\"#{actor.public_id}\">", escape(text), CLOSE].join("\n")
      end

      def escape(text) = text.to_s.gsub(FORGERS, LT)
      def unescape(text) = text.to_s.gsub(SPELLED, "<")

      # A turn's words as later history reads them: the seed of a reply
      # turn, the content of a user-role message turn. The voice is the
      # turn's SPEAKER (`speaker_actor`'s controlling User —
      # fork-stable), never `control_owner_user`: a fork's adopted
      # boundary turn hands control to the forker while keeping the
      # speaker, and a colleague's word must stay the colleague's there.
      # Judged against the turn's OWN answerer and its own conversation
      # (an inherited turn is judged where it was spoken, so a side's
      # prefix stays the parent's bytes).
      def for_turn(turn, text)
        speaker = turn.speaker_actor
        return ingress(speaker, text) if speaker.kind == "ingress"
        for_author(speaker.user, turn.conversation, text, answerer: turn.answering_user,
          origin: turn.origin, sender: turn.sender_conversation_public_id, author_id: speaker.user_id)
      end

      # A queued row's words as the wire reads them: the seed of the turn
      # it opens, or the steer tail of the round it lands in — judged
      # against the row's ADDRESSEE.
      def for_input(input, text = input.text)
        return ingress(input.speaker_actor, text) if input.speaker_actor.kind == "ingress"

        for_author(input.authoring_user, input.host, text, answerer: input.answering_user,
          origin: input.origin, sender: input.sender_conversation_public_id, author_id: input.authoring_user_id)
      end

      # The rule, once. `author` is loaded only when the words are wrapped;
      # the decision reads ids. `host` is the row's InputHost — a
      # Conversation or a standalone AgentLoop, both answering
      # `creating_user_id` and `answering_user`; `answerer` is the turn's,
      # the host's default when the caller names none.
      def for_author(author, host, text, origin: nil, sender: nil, author_id: nil, answerer: nil)
        return text if text.blank?
        return text unless wrapped?(host, author_id || author.id, origin: origin, sender: sender,
          answerer: answerer || host.answering_user)

        render(author: author, text: text, conversation: sender)
      end

      def wrapped?(host, author_id, origin:, sender:, answerer:)
        return false if ConversationInput::KERNEL_ORIGINS.include?(origin)
        return true if sender.present?

        !own_voice?(host, answerer, author_id)
      end

      def own_voice?(host, answerer, author_id)
        [host.creating_user_id, answerer.id, answerer.controlling_human&.id].include?(author_id)
      end
    end
  end
end
