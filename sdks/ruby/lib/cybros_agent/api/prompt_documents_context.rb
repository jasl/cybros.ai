module CybrosAgent
  module Api
    # THE PROMPT DOCUMENTS — three slots the default template compiles
    # ahead of everything else, behind two member-plane
    # doors that share one grammar.
    #
    # WHOSE each slot is: `system_prompt` is the agent's identity, anchored
    # on the Agent Profile User; `character` is the room's, anchored on the
    # Workspace; `persona` is the person's, anchored on the poster's
    # controlling Human. The workspace's door (`workspace.prompt_documents`)
    # serves `character` under the dedication fence — a fenced agent reads
    # it and never writes it; the profile's door
    # (`client.profile.prompt_documents`) serves the ACTING user's own slot —
    # an agent's `system_prompt`, a Human's `persona`. A slot a door's
    # anchor cannot hold is the kernel's `prompt_slot_unavailable`, typed
    # as `InvalidRequest`, before any row is touched.
    #
    # THE SLOT IS THE PATH'S MEMBER SEGMENT — one word, never a slash —
    # which is why, unlike memory, every verb addresses it in the URL and
    # `write` is a PUT: a whole replacement, 200 whether first or later,
    # `version` counting the writes. The content rides as written — the
    # macros `{{agent}} {{user}} {{workspace}} {{date}}` are substituted by
    # the assembler at compile, and a word outside that registry is the
    # kernel's `prompt_document_macro_unknown` naming it, so a typo never
    # reaches a model as literal braces.
    #
    # Nothing here bumps a conversation: the next turn of every conversation
    # reads the slot live.
    class PromptDocumentsContext
      include ConversationProjections
      include Fields

      attr_reader :path

      # `path` is the door: the slot collection this context reads and
      # writes, already spelled by the owning context.
      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = required_string_snapshot(path, "path")
      end

      # Every slot this door holds. Sizes, versions and ages only — `read`
      # is what loads text.
      def list = shapes(PromptDocument, @dispatch.call(path), "prompt_documents")

      def read(slot)
        shape(PromptDocument, @dispatch.call(slot_path(slot)), "prompt_document")
      end

      # WHOLE-DOCUMENT REPLACE by URL — idempotent by construction, so no
      # Idempotency-Key. `role` is the block's role in the sealed list
      # (`system`, the kernel's default when unsent; `developer`; `user`) —
      # a role other than `system` breaks the leading system run and
      # stands as its own item, the author's choice.
      def write(slot, content, role: UNSET)
        shape(PromptDocument, @dispatch.call(slot_path(slot), method: :put,
              body: { "prompt_document" => fields(content:, role:) }), "prompt_document")
      end

      # Gone for good — no history. The sealed requests that compiled it
      # keep the bytes they were sent.
      def delete(slot)
        @dispatch.call(slot_path(slot), method: :delete, success: 204)
        nil
      end

      private

        def slot_path(slot)
          "#{path}/#{path_segment(slot, "slot")}"
        end
    end
  end
end
