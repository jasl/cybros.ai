require "rho/schedule_commands"

module Rho
  module IngressTelegram
    module ScheduleBridge
      def schedule_command(conversation_id, command:, workspace_public_id:, model: nil, to: nil,
                                speaker_public_id: nil, tool_names: nil, idempotency_key: nil)
        Rho::ScheduleCommands.execute(@core, conversation_id, command, workspace_public_id: workspace_public_id,
          model: model, to: to, speaker_public_id: speaker_public_id,
          tool_names: tool_names, idempotency_key: idempotency_key)
      end

      def schedules(conversation_id, after: nil, workspace_public_id:)
        @core.schedules(conversation_id, after: after, workspace_public_id: workspace_public_id)
      end

      def schedule(conversation_id, job_id, workspace_public_id:)
        @core.schedule(conversation_id, job_id, workspace_public_id: workspace_public_id)
      end

      def schedule_executions(conversation_id, job_id, after: nil, workspace_public_id:)
        @core.schedule_executions(conversation_id, job_id, after: after, workspace_public_id: workspace_public_id)
      end

      def schedule_answerer(isolated:)
        group_agent if isolated
      end

      def read_only_schedule?(row, conversation_id:, workspace_public_id:)
        row.fetch("answering_user_public_id") == group_agent && row["tool_names"] &&
          (row.fetch("tool_names") - read_only_tool_names(conversation_id, group: true, workspace_public_id: workspace_public_id)).empty?
      end
    end
  end
end
