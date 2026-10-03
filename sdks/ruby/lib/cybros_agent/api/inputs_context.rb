module CybrosAgent
  module Api
    # THE WAITING ROOM — one host's input queue, which is the only way
    # anything enters its plane. A conversation hosts it at
    # `conversations/{id}/inputs`; a standalone agent loop hosts the same
    # door at `agent_loops/{id}/inputs`, and the path is the one thing that
    # differs, so it is the one thing this takes.
    #
    # A `message` is what a speaker said; a `direct_reply` is a request for
    # the model to answer, and it carries the model selection. Both wait as
    # DURABLE ROWS until the kernel materializes them at a turn boundary,
    # FIFO. An idle conversation drains immediately; a busy one at the next
    # boundary — which is why enqueueing never fails for being mid-run.
    #
    # A LOOP HOST admits `message` only, from a `user` only, and nothing
    # that names a model or an assembly (422 `validation_failed` naming the
    # field); a `steer` binds to the loop's one running turn and a queued
    # word is its follow-up, landed before the turn-shaped `completed`. A
    # settled loop refuses 409 `agent_loop_settled`; a loop-backed loop's
    # door is its conversation's, 409 `conversation_hosted` naming it.
    #
    # A BLOCKED HEAD STOPS THE QUEUE. That is the contract, not a bug:
    # skipping it would reorder what the sender ordered. `blocked_reason`
    # says why, and `update` on that row is the unblock path.
    class InputsContext
      include ConversationProjections
      include Fields

      attr_reader :path

      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = required_string_snapshot(path, "path")
      end

      # The whole queue in order, with the occupancy a caller needs before
      # adding to it.
      def list = shape(ConversationInputList, @dispatch.call(path))

      # ENQUEUE. `text` is the ordinary spelling; `entries` is the raw
      # escape hatch (a verbatim message list, sent with no history and no
      # merging) and the two are mutually exclusive.
      #
      # The optimistic fences are worth the extra field when they apply:
      # `expected_context_revision` and `expected_tail_turn_public_id`
      # refuse the send if the conversation moved under the caller since it
      # last read — which is the difference between a reply to what the
      # user saw and a reply to something else.
      # `expected_steering_loop_public_id` additionally pins a conversation
      # steer to one running execution: a mismatch refuses, and unconsumed
      # words are canceled when that execution ends instead of queueing.
      #
      # `tool_names` is the turn's tool subset: the declaring profile's flat
      # tool names this reply runs with (a subset of its declaration, never
      # an addition — an undeclared name is 422 `validation_failed` naming
      # it); unset runs with the whole declaration. Frozen onto the turn at
      # materialization beside its model, and a conversation-door field
      # only — the loop's one turn carries its seed's tools.
      #
      # `approval_mode` is the turn's TIGHTENING of the declaring profile's
      # approval mode (the `tool_names` precedent): a word
      # that only ever ranks stricter — bypass → ask → rules — refused 422
      # `validation_failed` naming it otherwise; unset runs with the
      # profile's word. Frozen onto the loop row at materialization, a
      # reply-lane field, and refused by name on the loop door.
      #
      # `instructions` is the system field under `context_mode: raw` — the
      # `raw` grammar's one field outside `entries`, sealed as sent in the
      # wire's own slot; refused 422 on an assembled input, whose system
      # text is the slot blocks the kernel compiles into the list. `inline:` passes through as given — an entry naming a
      # `slot` (`{slot:, text:, role?}`) replaces that slot's registered
      # document for this turn, and needs no grammar here.
      #
      # `to:` is WHO ANSWERS this turn (group chat): a member
      # by `@handle` or public id — the wire's `answering_user_public_id`,
      # the create door's word — an agent of the account holding `full`
      # here; unset is the conversation's stored answerer. Create-only:
      # the kernel drops it from an update. An unknown name is 422
      # `principal_unknown`, an ineligible one 422 `answerer_not_eligible`.
      #
      # `attachments:` are PICTURES BESIDE THE WORDS: the caller's
      # own staged uploads — the ids, or the `Upload` values
      # `uploads.create` answered — composed after the text in the order
      # given, bound for liveness, images only (`422
      # unsupported_input_media` otherwise). A steer takes none (`422
      # attachments_not_steerable`), and they never ride beside `entries`:
      # the raw grammar places its own `upload` parts. On an update an
      # absent `attachments` KEEPS the row's pictures across a text edit;
      # `[]` unbinds them; a list rebinds.
      #
      # `deliver_at:` / `deliver_in:` are NOT BEFORE this time: exactly one — `deliver_at` a `Time` (sent in UTC) or
      # an ISO 8601 string WITH an offset sent as given (a naive one is the
      # kernel's `400 parameter_invalid`), `deliver_in` a delay from now
      # (`90s`, `20m`, `2h`, `1d`) the kernel resolves against its own
      # clock. The row is accepted now, waits at its arrival position, and
      # is invisible to the drain until the time passes; `queue` only
      # (`422 deliver_at_not_steerable` beside `steer`); more than two
      # minutes past is `422 deliver_at_in_past`, more than ten years ahead
      # `422 deliver_at_too_far`, both fields `422 deliver_at_ambiguous`;
      # the loop door refuses it by name. `delete` cancels it. The row's
      # `deliver_at` is the ISO string the kernel holds.
      #
      # Creation demands the caller's own Idempotency-Key: a retry the
      # caller cannot recognize as a retry is how one message becomes two.
      def create(idempotency_key:, text: UNSET, entries: UNSET, kind: UNSET, role: UNSET,
                 model: UNSET, reasoning_effort: UNSET, configuration: UNSET,
                 delivery_mode: UNSET, context_mode: UNSET, history: UNSET,
                 reasoning_replay: UNSET, inline: UNSET, visible_in_context: UNSET,
                 expected_context_revision: UNSET, expected_tail_turn_public_id: UNSET, expected_steering_loop_public_id: UNSET,
                 tool_names: UNSET, approval_mode: UNSET, instructions: UNSET, to: UNSET,
                 attachments: UNSET, variables: UNSET, deliver_at: UNSET, deliver_in: UNSET, speaker_actor_public_id: UNSET)
        required_string(idempotency_key, "idempotency_key")
        refuse_text_beside_entries(text, entries, attachments)

        # `variables`: the turn's values for the names the
        # addressee's template declares, beside `history` and `inline` —
        # admitted only when the addressee's standing word is `assembly`;
        # the kernel refuses an undeclared name by name.
        body = fields(
          text:, entries:, kind:, role:, delivery_mode:, context_mode:, visible_in_context:,
          history:, reasoning_replay:, inline:, variables:, configuration:, tool_names:, approval_mode:,
          instructions:, expected_context_revision:, expected_tail_turn_public_id:, expected_steering_loop_public_id:,
          answering_user_public_id: to, speaker_actor_public_id:,
          attachments: attachment_ids(attachments),
          model: model_fields(model, reasoning_effort),
          deliver_at: deliver_at_field(deliver_at), deliver_in:
        )

        result = @dispatch.call_accepting(
          path, method: :post, body: { "input" => body },
          headers: { "Idempotency-Key" => idempotency_key }, success: 202
        )
        Accepted.new(
          input: shape(ConversationInput, result.body, "input"),
          replayed: result.replayed
        )
      end

      # THE UNBLOCK PATH, and the edit-while-queued path — the same call.
      # `expected_lock_version` is the optimistic fence: a row someone else
      # changed refuses rather than overwriting. `tool_names: []` is NO
      # TOOLS, as on the create — back to the whole declaration is the
      # declaration by name; `approval_mode` has no clear gesture either —
      # send the profile's own word, rank-equal is lawful. `deliver_at:` /
      # `deliver_in:` reschedule (the same two bounds as on create); no
      # keyword keeps the row's time; `deliver_in: "0s"` makes it due now
      # — the clear is a typed value, never a null.
      def update(public_id, expected_lock_version: UNSET, text: UNSET, entries: UNSET,
                 model: UNSET, reasoning_effort: UNSET, configuration: UNSET,
                 context_mode: UNSET, history: UNSET, reasoning_replay: UNSET,
                 inline: UNSET, visible_in_context: UNSET, tool_names: UNSET,
                 approval_mode: UNSET, instructions: UNSET, attachments: UNSET, variables: UNSET,
                 deliver_at: UNSET, deliver_in: UNSET)
        refuse_text_beside_entries(text, entries, attachments)

        body = fields(
          text:, entries:, context_mode:, visible_in_context:, history:, reasoning_replay:,
          inline:, variables:, configuration:, tool_names:, approval_mode:, instructions:,
          attachments: attachment_ids(attachments),
          expected_lock_version:, model: model_fields(model, reasoning_effort),
          deliver_at: deliver_at_field(deliver_at), deliver_in:
        )

        answer = @dispatch.call(input_path(public_id), method: :patch, body: { "input" => body })
        shape(ConversationInput, answer, "input")
      end

      # GIVE UP A ROW. On a steering input this IS steer-cancel — the row
      # and the intent are the same thing.
      def delete(public_id)
        @dispatch.call(input_path(public_id), method: :delete, success: 204)
        nil
      end

      # AN EXACT SET, not a move: the server refuses a list that is not a
      # permutation of what is queued, so a reorder racing an arrival
      # cannot silently drop the arrival.
      def reorder(ordered_public_ids)
        body = { "inputs" => Array(ordered_public_ids) }
        shapes(ConversationInput, @dispatch.call("#{path}/reorder", method: :post, body: body), "inputs")
      end

      private

        # UNSET when no model is named, so the field is omitted whole.
        def model_fields(model, reasoning_effort)
          field(model) { fields(model:, reasoning_effort:) }
        end

        # `entries` is the raw grammar and stands alone: neither the
        # ordinary `text` nor its `attachments` ride beside it.
        def refuse_text_beside_entries(text, entries, attachments)
          return if UNSET.equal?(entries)

          raise ArgumentError, "give text or entries, never both" unless UNSET.equal?(text)
          raise ArgumentError, "attachments ride beside text, never beside entries" unless UNSET.equal?(attachments)
        end

        # An `Upload` value spells its own id; a string is one already.
        def attachment_ids(attachments)
          field(attachments) do |given|
            Array(given).map do |attachment|
              attachment.is_a?(Upload) ? attachment.public_id : required_string(attachment, "attachments")
            end
          end
        end

        # A `Time` spells itself in UTC (the wire's one zone); a string is
        # sent as given — the kernel is the one parser of the shape.
        def deliver_at_field(deliver_at)
          field(deliver_at) do |given|
            case given
            when Time then given.utc.iso8601
            else required_string(given, "deliver_at")
            end
          end
        end

        def input_path(public_id)
          "#{path}/#{path_segment(public_id, "public_id")}"
        end

      # What `create` answers: the QUEUED row, and whether the server
      # recognized this Idempotency-Key from an earlier request. The turn
      # it becomes does not exist yet — follow the host's feed.
      Accepted = Data.define(:input, :replayed) do
        def replayed? = replayed

        def public_id = input.public_id
        def queue_position = input.queue_position
        def state = input.state
        def blocked? = input.blocked?
      end
    end
  end
end
