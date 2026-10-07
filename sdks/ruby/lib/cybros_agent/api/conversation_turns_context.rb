module CybrosAgent
  module Api
    # THE TIMELINE and its decks. A turn is one slot; a variant is one
    # candidate answer for that slot, and a turn points at exactly one as
    # active. Regeneration and edit both ADD to the deck rather than
    # replacing what is there — which is why a swipe back is free and why
    # nothing here is a content-losing verb except `delete`.
    #
    # INHERITED TURNS ARE READ-ONLY FROM HERE. A forked conversation reads
    # its ancestor's rows through the closure: same `public_id`, one row,
    # one identity. Its view state is settable (that is what the override
    # overlay is for) but its content is the ancestor's.
    class ConversationTurnsContext
      include ConversationProjections
      include Fields

      attr_reader :workspace_public_id, :conversation_public_id

      def initialize(dispatch:, workspace_public_id:, conversation_public_id:)
        @dispatch = dispatch
        @workspace_public_id = required_string_snapshot(workspace_public_id, "workspace_public_id")
        @conversation_public_id =
          required_string_snapshot(conversation_public_id, "conversation_public_id")
      end

      # A POSITION WINDOW, not a keyset page: positions are this
      # conversation's own ordering and survive concealment (a soft-deleted
      # turn keeps its slot forever, so history never renumbers). At most
      # one of the two cursors may be given. `include_hidden: true` reads
      # hidden turns for management and execution recovery; concealed turns
      # remain absent and each returned turn keeps its visibility.
      def list(after_position: nil, before_position: nil, limit: nil, include_hidden: nil)
        if after_position && before_position
          raise ArgumentError, "give after_position or before_position, never both"
        end


        shape(ConversationTurnPage, @dispatch.call(path,
          params: query(after_position:, before_position:, limit:, include_hidden:)))
      end

      # One reachable turn, with the same effective visibility as a window.
      # A separately running regeneration rides running_variant; active_variant
      # remains the answer the conversation currently displays.
      def fetch(public_id, include_hidden: nil)
        shape(ConversationTurn, @dispatch.call(turn_path(public_id),
          params: query(include_hidden:)), "turn")
      end

      # VIEW STATE, which is the non-destructive half of removal.
      # `visibility` moves a turn out of assembly while it stays on the
      # timeline (`excluded_from_context`) or off the timeline entirely
      # (`hidden`); `concealed` is the mid-history soft delete. On an
      # inherited turn both write an OVERRIDE — the ancestor's row is never
      # touched.
      def set_view_state(public_id, visibility: UNSET, concealed: UNSET)
        body = fields(visibility:, concealed:)
        raise ArgumentError, "provide visibility or concealed" if body.empty?

        turn = fetch_hash(
          @dispatch.call(turn_path(public_id), method: :patch, body: { "turn" => body }),
          "turn"
        )
        TurnReference.new(
          public_id: string(turn, "public_id"), inherited: turn["inherited"] == true
        )
      end

      # THE APEX — and only the apex — physically removes. Deleting the
      # newest turn is the destructive undo every surveyed product ships;
      # `set_view_state(concealed: true)` is the mid-history tool, and the
      # split is what keeps delete-then-restore from being incoherent.
      def delete(public_id)
        @dispatch.call(turn_path(public_id), method: :delete, success: 204)
        nil
      end

      # REPLACE THE CONTENT with a new activated candidate. The original
      # stays in the deck: an edit is an addition, like everything else here.
      def edit(public_id, text: UNSET, entries: UNSET)
        if UNSET.equal?(text) == UNSET.equal?(entries)
          raise ArgumentError, "give text or entries, exactly one"
        end

        shape(ConversationVariant, @dispatch.call("#{turn_path(public_id)}/edit", method: :post,
              body: { "edit" => fields(text:, entries:) }), "variant")
      end

      # ASK AGAIN — the same request, a new sample beside the original,
      # optionally on a different model. Asynchronous like every other
      # send: the original keeps being rendered while the new sample runs,
      # and a COMPLETED sample becomes what the timeline shows. Nothing is
      # lost either way — the previous answer stays in the deck, and
      # `activate` is how a caller goes back to it. A RUN-BACKED turn
      # (its active variant `run_backed?`) regenerates as a NEW candidate
      # with its OWN run: the answer's variant is `run_backed?` and
      # names the new `run_public_id`; the old candidate keeps its
      # run and rounds. The kernel judges nothing about the world the old
      # run changed — the deck's `runner_effects` says what happened, and whether
      # to restore it first is the caller's. While the origin's run is
      # `needs_attention` the door refuses `run_needs_attention` (409):
      # adjudicate it first.
      # The caller's key identifies one regeneration, including after it
      # completes. Reuse it only to recover the same request's acceptance.
      def regenerate(public_id, idempotency_key:, model: UNSET, reasoning_effort: UNSET, reasoning_enabled: UNSET, configuration: UNSET)
        required_string(idempotency_key, "idempotency_key")
        # A control-only override keeps the current model on the server.
        body = fields(model: optional_fields(model:, reasoning_effort:, reasoning_enabled:), configuration:)

        result = @dispatch.call_accepting("#{turn_path(public_id)}/regeneration", method: :post,
          body: { "regeneration" => body }, headers: { "Idempotency-Key" => idempotency_key }, success: 202)
        shape(ConversationRegeneration, result.body).with(replayed: result.replayed)
      end

      # Recover this caller's acceptance before repeating application work.
      # NotFound means no retained receipt; any other failure is unknown.
      # POST with the same key still verifies the complete request digest.
      def regeneration_receipt(idempotency_key:)
        params = { "idempotency_key" => required_string(idempotency_key, "idempotency_key") }
        answer = @dispatch.call("#{conversation_path}/regeneration_receipt", params: params)
        shape(ConversationRegeneration, answer).with(replayed: true)
      end

      # The deck: every LIVE candidate for a reachable turn, with the
      # active one flagged. A concealed row's content never rides a payload.
      def variants(public_id)
        shape(ConversationVariantDeck, @dispatch.call(variants_path(public_id)))
      end

      # THE DEBUG DOOR: the bytes ONE candidate's request
      # was sealed with — exactly the entries and the request options,
      # derived from the sealed body and never re-assembled — for reading
      # what a model saw: the slot blocks, memory, history, the inline lead,
      # the prompt, in the order the assembler placed them. A run-backed
      # variant answers its first round's (every later round is the run
      # door's, `run_task(...).request`); a candidate whose reply
      # never minted is the kernel's 404 `request_not_sealed`. Browse
      # standing suffices.
      def request(public_id, variant_public_id)
        answer = @dispatch.call(
            "#{variants_path(public_id)}/#{path_segment(variant_public_id, "variant_public_id")}/request"
        )
        shape(SealedRequest, answer, "request")
      end

      # Display text for this candidate's selected model rounds. The opaque
      # cursor walks older rounds; encrypted/native replay is never returned.
      def reasoning(public_id, variant_public_id, before: nil, limit: nil)
        answer = @dispatch.call(
          "#{variants_path(public_id)}/#{path_segment(variant_public_id, "variant_public_id")}/reasoning",
          params: query(before:, limit:)
        )
        shape(ConversationReasoningPage, answer)
      end

      # THE SWIPE. Activating another settled candidate makes it the turn's
      # rendered answer, and the one it replaced stays in the deck.
      def activate(public_id, variant_public_id)
        answer = @dispatch.call(
            "#{variants_path(public_id)}/#{path_segment(variant_public_id, "variant_public_id")}/activation",
            method: :post
        )
        shape(ConversationVariant, answer, "variant")
      end

      # Conceal or restore ONE candidate. Distinct from the turn's own
      # concealment: this hides a sample, that hides the slot.
      def set_variant_view_state(public_id, variant_public_id, concealed:)
        answer = @dispatch.call(
            "#{variants_path(public_id)}/#{path_segment(variant_public_id, "variant_public_id")}",
            method: :patch, body: { "variant" => { "concealed" => concealed } }
        )
        shape(ConversationVariant, answer, "variant")
      end

      private

        def path = "#{conversation_path}/turns"

        def conversation_path
          "#{Workspaces::PATH}/#{path_segment(@workspace_public_id, "workspace_public_id")}" \
            "/conversations/#{path_segment(@conversation_public_id, "conversation_public_id")}"
        end

        def turn_path(public_id)
          "#{path}/#{path_segment(public_id, "public_id")}"
        end

        def variants_path(public_id)
          "#{turn_path(public_id)}/variants"
        end

      # What the view-state writer answers: which turn, and whether the
      # change landed on an override rather than on the row itself.
      TurnReference = Data.define(:public_id, :inherited) do
        def inherited? = inherited
      end
    end
  end
end
