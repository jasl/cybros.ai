module Schedules
  # The parent row serializes both dispatch and schedule management. Birth,
  # input acceptance and the clock advance commit together in the primary DB.
  #
  # `by` names a person running the job now: the same child birth under the
  # job's saved intent and its creator's standing, outside the clock. The
  # rule's next occurrence and the status are left as they are.
  class Dispatch
    def self.call(...) = new(...).call

    def initialize(id:, cutoff: DatabaseClock.now, by: nil)
      @id = id
      @cutoff = cutoff
      @by = by
    end

    def call
      @job = Schedule.find_by(id: @id)
      return :not_found unless @job

      @parent = @job.conversation
      @parent.with_lock(requires_new: true) do
        @job.reload
        refusal = @by ? immediate_refusal : clock_refusal
        next refusal if refusal

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

      def clock_refusal
        :not_due unless @job.active? && @job.next_run_at && @job.next_run_at <= @cutoff
      end

      # A finished job has nothing left to run; the actor needs write standing
      # on the parent like every other schedule command.
      def immediate_refusal
        return :schedule_finished if @job.canceled? || @job.completed?
        :not_authorized unless @parent.writable_by?(@by)
      end

      def authority_refusal
        return @parent.input_refusal if @parent.input_refusal
        return :not_authorized unless @parent.writable_by?(@job.creating_user)
        :answerer_not_eligible unless @parent.answerer_eligible?(@job.answering_user)
      end

      def birth
        declaration = @job.agent_configuration
        created = Conversations::Create.call(Conversations::Create::Command.new(
          workspace: @parent.workspace, creating_user: @job.creating_user,
          title: @job.name, metadata: nil, billing_subject: nil,
          answering_user_public_id: @job.answering_user.public_id,
          default_runner_executor_public_id: @parent.default_runner&.public_id,
          parent: @parent, schedule: @job, scheduled_for: @by ? @cutoff : @job.next_run_at,
          memory_context: @parent.memory_context, conversation_reach: @parent.conversation_reach,
          agent_configuration: declaration, model_selection: @job.model_selection,
          fallback_models: @job.fallback_models
        ))
        return created unless created.accepted?

        child = created.value
        accepted = Conversations::Inputs::Create.call(input_command(child))
        return accepted unless accepted.accepted?

        Conversations::Outcome.accepted([child, accepted.value])
      end

      # The clock moves only for its own occurrence: an immediate run records
      # its execution and leaves the next occurrence where the rule put it.
      def advance(**attributes)
        if @by
          @job.update!(attributes)
        else
          following = @job.parsed_rule.next_after(@cutoff)
          @job.update!(attributes.merge(next_run_at: following, status: following ? "active" : "completed"))
        end
      end

      def input_command(child)
        Conversations::Inputs::Create::Command.new(
          host: child, acting_user: @job.creating_user, kind: "direct_reply", role: "user",
          entries: [{ "text" => @job.prompt }], visible_in_context: true, delivery_mode: "queue",
          context_mode: "assembled", context_options: nil,
          expected_context_revision: nil, expected_tail_turn_public_id: nil,
          provider_id: @job.provider_id, model_ref: @job.model_ref, reasoning_effort: @job.reasoning_effort,
          reasoning_enabled: @job.reasoning_enabled,
          model_selection: @job.model_selection || child.model_selection, fallback_models: @job.fallback_models || child.fallback_models,
          request_options: @job.configuration, tool_names: @job.tool_names, approval_mode: @job.approval_mode,
          answering_user_public_id: @job.answering_user.public_id, speaker_public_id: @job.speaker_public_id
        )
      end

      def record_refusal(code)
        @job.update!(last_error_code: code.to_s) unless @job.last_error_code == code.to_s
        code
      end

      # A refused child birth rolled back its Speaker, content and event writes.
      # Persist only the schedule's diagnostic under the same parent arbiter.
      def record_failed_birth
        @parent.with_lock do
          @job.reload
          record_refusal(@refusal) if @job.active?
        end
      end
  end
end
