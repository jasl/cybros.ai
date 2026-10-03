module AgentAPI
  class ScheduledJobPresenter
    def self.basic(job, executions: {})
      {
        public_id: job.public_id,
        conversation_public_id: job.conversation.public_id,
        creating_user_public_id: job.creating_user.public_id,
        answering_user_public_id: job.answering_user.public_id,
        speaker_actor_public_id: job.speaker_actor_public_id,
        source_agent_loop_public_id: job.source_agent_loop_public_id, source_task_key: job.source_task_key,
        name: job.name, prompt: job.prompt, rule: job.rule,
        model: { model: "#{job.provider_id}/#{job.model_ref}", reasoning_effort: job.reasoning_effort },
        configuration: job.configuration, tool_names: job.tool_names, approval_mode: job.approval_mode,
        status: job.status, lock_version: job.lock_version,
        next_run_at: job.next_run_at, last_enqueued_at: job.last_enqueued_at,
        last_input_public_id: job.last_input_public_id, last_error_code: job.last_error_code,
        last_execution: executions[job.last_execution_conversation_id],
        created_at: job.created_at, updated_at: job.updated_at,
      }
    end

    def self.many(jobs, by:, workspace:)
      visible = Conversation.visible_to(by, workspace: workspace)
        .where(id: jobs.filter_map(&:last_execution_conversation_id)).pluck(:id)
      executions = ScheduledJobs::ExecutionProjection.call(visible)
      jobs.map { |job| basic(job, executions: executions) }
    end

    def self.full(job, by:) = many([job], by: by, workspace: job.conversation.workspace).sole
  end
end
