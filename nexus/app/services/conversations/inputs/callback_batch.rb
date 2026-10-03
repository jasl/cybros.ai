module Conversations
  module Inputs
    # Read a bounded prefix of already-arrived receipts into one reply. The
    # preceding receipts keep their own message turns, bodies and input events;
    # the last receipt opens the reply whose normal history includes them.
    # Ordinary task mail retains its execution owner. Independent worker finals
    # can share a reply when their requester and execution surfaces agree.
    module CallbackBatch
      CALLBACK_FIT_REFUSAL = :callback_batch_does_not_fit
      CALLBACK_BATCH_LIMIT = 16
      CALLBACK_SURFACE_FIELDS = %w[
        authoring_user_id answering_user_id speaker_actor_id sender_agent_loop_public_id
        role provider_id model_ref reasoning_effort request_options tool_names approval_mode
      ].freeze

      private

        def materialize_callbacks(head, callbacks)
          return materialize_reply(head) if callbacks.one?

          @batching_callbacks = true
          @independent_callback_sources = callbacks.map(&:callback_source) if head.callback_result
          result = nil
          ApplicationRecord.transaction(requires_new: true) do
            callbacks[0...-1].each { |input| materialize(input, kind: "message") }
            result = materialize_reply(callbacks.last)
            unless @callback_history_complete && result.accepted? && result.value.kind == "direct_reply"
              result = nil
              raise ActiveRecord::Rollback
            end
          end
          return result if result

          # The savepoint restores rows and their events. Restore the local
          # objects and wake intent too before taking the ordinary head path.
          @batching_callbacks = false
          @callback_history_complete = false
          @materialized_loop_id = nil
          @mail_fallback = nil
          @independent_callback_sources = nil
          @conversation.reload
          materialize_reply(@conversation.conversation_inputs.find(head.id))
        ensure
          @batching_callbacks = false
          @callback_history_complete = false
          @independent_callback_sources = nil
        end

        def callback_history_refusal(assembled, template)
          return unless @batching_callbacks

          # Requiring an uncut history is deliberately conservative: it
          # avoids coupling receipt ownership to history's segment layout.
          # Keep the author's exact caps and process individually if any
          # history was omitted, including by an explicit template limit.
          @callback_history_complete = template.history.present? && assembled.history.skipped_count.zero?
          CALLBACK_FIT_REFUSAL unless @callback_history_complete
        end

        def callback_batch(head, candidates)
          return [head] unless batchable_callback?(head)
          requester = head.callback_result&.fetch("requester_actor_public_id")
          return [head] if head.callback_result && requester.nil?

          fields = requester ? CALLBACK_SURFACE_FIELDS - ["sender_agent_loop_public_id"] : CALLBACK_SURFACE_FIELDS
          surface = head.attributes.slice(*fields)
          memory_context = head.execution_memory_context
          bytes = 0
          bound = Nexus::SizeBounds.fetch(:snapshot_bound)
          rows = candidates.limit(CALLBACK_BATCH_LIMIT).includes(:content_bodies)
          selected = rows.take_while do |input|
            next false unless batchable_callback?(input) && input.attributes.slice(*fields) == surface
            next false unless input.execution_memory_context == memory_context
            if requester
              next false unless input.callback_result&.fetch("requester_actor_public_id") == requester
            else
              next false if input.callback_result
            end

            bytes += input.content_body&.byte_size || 0
            bytes <= bound
          end
          selected.empty? ? [head] : selected
        end

        def batchable_callback?(input)
          input.kernel_origin? && input.kind == "direct_reply" && input.state == "pending" &&
            input.sender_agent_loop_public_id.present? && input.visible_in_context &&
            input.context_mode == "assembled" && input.context_options.empty? && input.instructions.blank? &&
            input.expected_context_revision.nil? && input.expected_tail_turn_public_id.nil?
        end
    end
  end
end
