require "rho/scheduled_job_commands"

module Rho
  module IngressTelegram
    module ScheduledJobBridge
      def scheduled_job_command(conversation_id, command:, workspace_public_id:, model: nil, to: nil,
                                speaker_actor_public_id: nil, tool_names: nil, idempotency_key: nil)
        Rho::ScheduledJobCommands.execute(@core, conversation_id, command, workspace_public_id: workspace_public_id,
          model: model, to: to, speaker_actor_public_id: speaker_actor_public_id,
          tool_names: tool_names, idempotency_key: idempotency_key)
      end

      def scheduled_jobs(conversation_id, after: nil, workspace_public_id:)
        @core.scheduled_jobs(conversation_id, after: after, workspace_public_id: workspace_public_id)
      end

      def scheduled_job(conversation_id, job_id, workspace_public_id:)
        @core.scheduled_job(conversation_id, job_id, workspace_public_id: workspace_public_id)
      end

      def scheduled_job_executions(conversation_id, job_id, after: nil, workspace_public_id:)
        @core.scheduled_job_executions(conversation_id, job_id, after: after, workspace_public_id: workspace_public_id)
      end

      def scheduled_job_answerer(isolated:)
        group_agent if isolated
      end

      def read_only_scheduled_job?(row)
        row.fetch("answering_user_public_id") == group_agent && row["tool_names"] &&
          (row.fetch("tool_names") - read_only_tool_names(group: true)).empty?
      end
    end
  end
end
