module ScheduledJobs
  # The parent row serializes both dispatch and schedule management. Birth,
  # input acceptance and the clock advance commit together in the primary DB.
  class Dispatch
    def self.call(...) = new(...).call

    def initialize(id:, cutoff: DatabaseClock.now)
      @id = id
      @cutoff = cutoff
    end

    def call
      @job = ScheduledJob.find_by(id: @id)
      return :not_found unless @job

      @parent = @job.conversation
      @parent.with_lock(requires_new: true) do
        @job.reload
        next :not_due unless @job.active? && @job.next_run_at && @job.next_run_at <= @cutoff

        refusal = authority_refusal
        next record_refusal(refusal) if refusal

        if Execution.unfinished?(@job.last_execution_conversation)
          advance(last_error_code: "execution_in_progress")
          next :execution_in_progress
        end

        result = birth
        unless result.accepted?
          @refusal = result.invalid? ? :invalid_input : result.outcome
          raise ActiveRecord::Rollback
        end

        child, input = result.value
        child.update!(scheduled_input_public_id: input.public_id)
        advance(last_execution_conversation: child, last_input_public_id: input.public_id,
          last_enqueued_at: @cutoff, last_error_code: nil)
        :dispatched
      end.tap do
        record_failed_birth if @refusal
      end
    rescue ActiveRecord::RecordNotFound
      :not_found
    end

    private

      def authority_refusal
        return @parent.input_refusal if @parent.input_refusal
        return :not_authorized unless @parent.writable_by?(@job.creating_user)
        :answerer_not_eligible unless @parent.answerer_eligible?(@job.answering_user)
      end

      def birth
        created = Conversations::Create.call(Conversations::Create::Command.new(
          workspace: @parent.workspace, creating_user: @job.creating_user,
          title: @job.name, metadata: nil, billing_subject: nil,
          answering_user_public_id: @job.answering_user.public_id,
          parent: @parent, scheduled_job: @job, scheduled_for: @job.next_run_at,
          memory_context: @parent.memory_context
        ))
        return created unless created.accepted?

        child = created.value
        accepted = Conversations::Inputs::Create.call(input_command(child))
        return accepted unless accepted.accepted?

        Conversations::Outcome.accepted([child, accepted.value])
      end

      def advance(**attributes)
        following = @job.schedule.next_after(@cutoff)
        @job.update!(attributes.merge(next_run_at: following, status: following ? "active" : "completed"))
      end

      def input_command(child)
        Conversations::Inputs::Create::Command.new(
          host: child, acting_user: @job.creating_user, kind: "direct_reply", role: "user",
          entries: [{ "text" => @job.prompt }], visible_in_context: true, delivery_mode: "queue",
          context_mode: "assembled", context_options: nil,
          expected_context_revision: nil, expected_tail_turn_public_id: nil,
          provider_id: @job.provider_id, model_ref: @job.model_ref, reasoning_effort: @job.reasoning_effort,
          request_options: @job.configuration, tool_names: @job.tool_names, approval_mode: @job.approval_mode,
          answering_user_public_id: @job.answering_user.public_id, speaker_actor_public_id: @job.speaker_actor_public_id
        )
      end

      def record_refusal(code)
        @job.update!(last_error_code: code.to_s) unless @job.last_error_code == code.to_s
        code
      end

      # A refused child birth rolled back its Actor, content and event writes.
      # Persist only the schedule's diagnostic under the same parent arbiter.
      def record_failed_birth
        @parent.with_lock do
          @job.reload
          record_refusal(@refusal) if @job.active?
        end
      end
  end
end
