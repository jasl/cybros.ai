module Conversations
  module Inputs
    # A queued row stays the caller's to change until materialization seals
    # it; editing a blocked head is the unblock path. A held steer admits
    # only the Send now timing change; its content and target stay fixed. A kernel-origin row is nobody's to
    # change: `kernel_input_immutable`, by name — the kernel's SET, so a
    # peer's `send` stays the recipient's to manage.
    class Update
      EDITABLE_STATES = %w[pending blocked].freeze

      # `attachments`: nil KEEPS the binding — an edit that carries new
      # text re-composes the parts entry from that text plus the pictures
      # the row already binds, so the fix path for a blocked head never
      # loses the picture the reaper would then take; `[]` unbinds; a list
      # rebinds in that order (beside the row's words when the edit
      # carries none). `deliver_at`: NO tri-state — nil is UNTOUCHED, as
      # every member here; a Time RESCHEDULES under the door's own two
      # bounds, re-judged under the lock. The CLEAR is a typed value on
      # the wire (`deliver_in: "0s"`, the `context_options` precedent: nil
      # is untouched, `{}` is the clear gesture), which the boundary's one
      # parser resolves to now — inside the grace, due at the next
      # boundary, drained by the post-commit kick below.
      Command = Data.define(:host, :input_public_id, :acting_user,
        :expected_lock_version, :entries, :visible_in_context, :context_mode,
        :context_options, :provider_id, :model_ref, :reasoning_effort, :reasoning_enabled,
        :request_options, :tool_names, :approval_mode, :instructions, :attachments, :deliver_at, :steps, :delivery_mode) do
        def initialize(reasoning_enabled: nil, tool_names: nil, approval_mode: nil, instructions: nil, attachments: nil, deliver_at: nil, steps: nil, delivery_mode: nil,
                       **) = super
      end

      class << self
        def call(command)
          new(command).call
        end
      end

      def initialize(command)
        @command = command
        @host = command.host
      end

      def call
        unless @host.writable_by?(@command.acting_user)
          return Outcome.refused(:not_authorized)
        end

        result = nil
        # The wrapper-seam rule: the Rollback below needs a real savepoint.
        @host.with_lock(requires_new: true) do
          result = locked_update
          raise ActiveRecord::Rollback unless result.accepted?
        end
        if result.accepted?
          # Rescheduling a head can free ready rows behind it immediately.
          @host.wake_drain
          at = wake_at
          @host.wake_drain(at: at) if at
        end
        result
      end

      private

        def locked_update
          refusal = @host.input_refusal
          return Outcome.refused(refusal) if refusal

          refusal = Admission.refusal(host: @host, command: @command)
          return refusal if refusal

          # THE PICTURES BEFORE THE ROW LOCK: the edit pins
          # the uploads it binds `FOR KEY SHARE` before it takes the input
          # row — the create door's own order (compose, then the body
          # writer's owner lock) — so `content_uploads` ranks above
          # `conversation_inputs` on the ladder for both doors. The host
          # lock serializes every door of this conversation, so the
          # unlocked read of the row's body is the row's; the drain's
          # dispatch (loop → input row) is what the row lock guards, and
          # the row's state is read under it.
          found = @host.conversation_inputs.find_by(public_id: @command.input_public_id)
          return Outcome.refused(:not_found) if found.nil?
          return Outcome.refused(:kernel_input_immutable) if found.kernel_origin?

          return advance_steer(found) unless @command.delivery_mode.nil?

          message = recomposed_message(found)
          return Outcome.refused(message.refusal) if message && !message.accepted?

          # The row lock under the host lock: host → input row is the door's
          # order on either host.
          input = @host.conversation_inputs.lock.find_by(id: found.id)
          return Outcome.refused(:not_found) if input.nil?
          return Outcome.refused(:steering_held) if input.steering?
          return Outcome.refused(:not_found) unless EDITABLE_STATES.include?(input.state)

          # An optional fence: the caller's version rides on the row, and
          # the save's optimistic CAS refuses a stale one.
          input.lock_version = @command.expected_lock_version if @command.expected_lock_version

          refusal = schedule_refusal
          return refusal if refusal

          apply(input, message)
        rescue ActiveRecord::StaleObjectError
          Outcome.refused(:stale_object)
        end

        def advance_steer(found)
          input = @host.conversation_inputs.lock.find(found.id)
          unless input.steering? && ConversationInput::STEERING_MODES.include?(input.delivery_mode) &&
              @command.delivery_mode == "steer_now"
            input.errors.add(:delivery_mode, :invalid)
            return Outcome.invalid(input)
          end
          changed_fields = @command.to_h.compact.keys - Admission::PLUMBING - %i[delivery_mode expected_lock_version]
          return Outcome.refused(:steering_held) if changed_fields.any?
          if @command.expected_lock_version && @command.expected_lock_version != input.lock_version
            return Outcome.refused(:stale_object)
          end

          if input.delivery_mode != "steer_now"
            input.update!(delivery_mode: "steer_now")
            narrate(input)
          end
          input.wake_steering
          Outcome.accepted(input)
        end

        # THE CLOCK ON THE EDIT: the door's two bounds, judged once under
        # the host lock against the database's clock — read only when a time
        # was named, so an untimed edit costs no statement. The `now` read
        # here is the one the kick is measured against.
        def schedule_refusal
          at = @command.deliver_at
          return nil if at.nil?

          @now = DatabaseClock.now
          return Outcome.refused(Create::IN_PAST) if at < @now - Create::PAST_GRACE
          return Outcome.refused(Create::TOO_FAR) if at > @now + Create::FUTURE_BOUND

          nil
        end

        def wake_at
          at = @command.deliver_at
          at if at && @now && at > @now
        end

        # The edited message, composed and its pictures pinned, when the
        # edit carries content; nil for a column-only edit.
        def recomposed_message(input)
          return nil unless @command.entries || !@command.attachments.nil?

          recompose_message(input)
        end

        def apply(input, message)
          was_blocked = input.state == "blocked"
          input.assign_attributes(column_changes(input))
          if was_blocked
            # The edit is the fix: the head rejoins the queue and the drain
            # re-judges it with the new facts.
            input.state = "pending"
            input.blocked_reason = nil
          end
          return Outcome.invalid(input) unless input.save

          if message
            body = ContentBodies::Replace.call(
              owner: input, role: "input", entries: message.entries,
              uploads: message.uploads, readable_text: message.readable_text
            )
            return Outcome.refused(body.refusal) unless body.accepted?

            # Content lives off-row; a content-only edit still stamps the row.
            ConversationInput.where(id: input.id).touch_all
            input.reload
          end

          narrate(input)
          Outcome.accepted(input)
        end

        # The edited message as the body will store it: raw entries place
        # their own parts (never beside `attachments`); a text edit keeps
        # the row's pictures unless `attachments` names the new set; an
        # attachments-only edit keeps the row's words — which a raw body
        # has none of, so it refuses as `attachments` beside entries does.
        def recompose_message(input)
          entries = @command.entries
          attachments = @command.attachments
          body = input.content_body
          if entries && !ContentBodies::AttachedMessage.text_shaped?(entries)
            return refused_message(ContentBodies::AttachedMessage::WITH_ENTRIES) unless attachments.nil?

            return ContentBodies::AttachedMessage.placed(
              account: @host.account, creating_user: @command.acting_user, entries: entries
            )
          end

          words = entries ? entries.first&.fetch("text", nil) : body&.readable_text
          return refused_message(ContentBodies::AttachedMessage::WITH_ENTRIES) if entries.nil? && words.nil?

          if attachments.nil?
            return ContentBodies::AttachedMessage.from_uploads(text: words, uploads: body ? body.upload_parts : [])
          end

          ContentBodies::AttachedMessage.compose(
            account: @host.account, creating_user: @command.acting_user,
            text: words, attachments: attachments
          )
        end

        def refused_message(refusal) = ContentBodies::AttachedMessage::Result.refused(refusal)

        def column_changes(input)
          changes = {}
          unless @command.visible_in_context.nil?
            changes[:visible_in_context] = @command.visible_in_context
          end
          changes[:context_mode] = @command.context_mode if @command.context_mode
          # nil is untouched; {} is the CLEAR gesture (history: null over
          # the wire) — an empty hash must land, not be skipped as falsy.
          unless @command.context_options.nil?
            changes[:context_options] = @command.context_options
          end
          changes[:provider_id] = @command.provider_id if @command.provider_id
          changes[:model_ref] = @command.model_ref if @command.model_ref
          moved = (@command.provider_id && @command.provider_id != input.provider_id) ||
            (@command.model_ref && @command.model_ref != input.model_ref)
          if moved || !@command.reasoning_effort.nil?
            changes[:reasoning_effort] = @command.reasoning_effort
          end
          if moved || !@command.reasoning_enabled.nil?
            changes[:reasoning_enabled] = @command.reasoning_enabled
          end
          changes[:request_options] = @command.request_options if @command.request_options
          # nil is untouched; [] is NO TOOLS, as on the create; there is no
          # clear gesture — name the whole declaration, as approval_mode's
          # rule reads below.
          changes[:tool_names] = @command.tool_names unless @command.tool_names.nil?
          # nil is untouched; there is no clear gesture — send the profile's
          # own word, a rank-equal tightening is lawful.
          changes[:approval_mode] = @command.approval_mode if @command.approval_mode
          # nil is untouched; the row's own validation refuses it off raw.
          changes[:instructions] = @command.instructions if @command.instructions
          # nil is untouched; a Time reschedules (the clear is a due time
          # the boundary resolved, never a null).
          changes[:deliver_at] = @command.deliver_at if @command.deliver_at
          # nil keeps the queued work; [] clears it before materialization.
          changes[:steps] = @command.steps unless @command.steps.nil?
          changes
        end

        def narrate(input)
          ConversationEvent::Append.call(
            host: @host,
            items: [{
              type: "input_edited",
              payload: {
                "input_public_id" => input.public_id,
                "queue_position" => input.queue_position,
                "state" => input.state,
                "delivery_mode" => input.delivery_mode,
                "deliver_at" => input.deliver_at&.iso8601,
              }.compact,
            }]
          )
        end
    end
  end
end
