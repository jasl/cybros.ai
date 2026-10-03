module Conversations
  class ContextAssembly
    # The named sources every macro host of one assembly renders from: the
    # agent's display name, the person's, the room's name, today, conversation kind — plus the
    # template's variables, the turn's values over the defaults. One hash
    # for the slots and the template's inline blocks, so the two cannot
    # disagree about `{{date}}`. A source that is absent renders empty,
    # never the braces. `{{date}}` moves the stable prefix once a day — the
    # author's choice. `conversation` is the Conversation or a `Source` (a
    # standalone loop's room).
    module MacroSources
      module_function

      def call(conversation:, principal:, declaring_profile:, variables: {})
        source = Source.of(conversation)
        variables.merge(
          "agent" => declaring_profile&.display_name,
          "user" => principal.controlling_human&.display_name,
          "workspace" => source.workspace.name,
          "date" => Date.current.iso8601,
          "conversation_kind" => source.conversation_kind
        )
      end
    end
  end
end
