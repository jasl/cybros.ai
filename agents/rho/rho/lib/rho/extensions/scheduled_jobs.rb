require "json"
require "rho/runner"

module Rho
  module Extensions
    module ScheduledJobs
      NAME = "rho.scheduled_jobs".freeze

      class << self
        attr_reader :member_plane

        def register(api)
          @member_plane = api.host&.member_plane
          api.register_tool(Read, serves: :agent)
          api.register_tool(Manage, serves: :agent)
        end
      end

      # The tool's execution owns the workspace and conversation. It never
      # consults the daemon's selected conversation or opens a local timer.
      class Session
        class Unavailable < Rho::Error; end

        attr_reader :context, :workspace, :jobs

        def initialize
          @context = Rho::Runner::ExecutionContext.current
          raise Unavailable, "scheduled jobs require a conversation" unless context&.conversation_public_id

          context.raise_if_cancelled!
          plane = ScheduledJobs.member_plane&.call(host_public_id: context.conversation_public_id,
            workspace_public_id: context.workspace_public_id)
          raise Unavailable, "no member connection is available for this conversation" unless plane

          @workspace = plane.client.workspace(plane.workspace_public_id)
          @jobs = workspace.conversation(context.conversation_public_id).scheduled_jobs
        end

        def creation_fields
          raise Unavailable, "scheduled job creation requires its executing task" unless
            context.agent_loop_public_id && context.task_key

          loop_door = workspace.agent_loops.agent_loop(context.agent_loop_public_id)
          source = loop_door.fetch
          call = loop_door.task(context.task_key)
          raise Unavailable, "the calling model round is unavailable" unless call.declaring_task_key

          round = loop_door.task(call.declaring_task_key)
          raise Unavailable, "the calling round's execution policy is unavailable" unless
            source.approval_mode && source.turn&.answering_user_public_id && round.tool_definitions && round.task.model

          model = round.task.model
          {
            model: model.fetch("model"), reasoning_effort: model["reasoning_effort"],
            approval_mode: source.approval_mode,
            to: source.turn.answering_user_public_id,
            tool_names: round.tool_definitions.map { |entry| entry.dig("function", "name") || entry.fetch("name") },
            source_agent_loop_public_id: context.agent_loop_public_id, source_task_key: context.task_key,
            idempotency_key: "scheduled_job:#{context.agent_loop_public_id}:#{context.task_key}",
          }
        end
      end
    end
  end
end

require_relative "scheduled_jobs/read"
require_relative "scheduled_jobs/manage"
