require "json"
require "rho/runner"

module Rho
  module Extensions
    module Schedules
      NAME = "rho.schedules".freeze

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

        def initialize(member_plane: Schedules.member_plane)
          @context = Rho::Runner::ExecutionContext.current
          raise Unavailable, "scheduled jobs require a conversation" unless context&.conversation_public_id

          context.raise_if_cancelled!
          plane = member_plane&.call(host_public_id: context.conversation_public_id,
            workspace_public_id: context.workspace_public_id)
          raise Unavailable, "no member connection is available for this conversation" unless plane

          @workspace = plane.client.workspace(plane.workspace_public_id)
          @jobs = workspace.conversation(context.conversation_public_id).schedules
        end

        def creation_fields
          raise Unavailable, "scheduled job creation requires its executing task" unless
            context.run_public_id && context.task_key

          run_door = workspace.runs.run(context.run_public_id)
          source = run_door.fetch
          call = run_door.task(context.task_key)
          raise Unavailable, "the calling model round is unavailable" unless call.declaring_task_key

          round = run_door.task(call.declaring_task_key)
          raise Unavailable, "the calling round's execution policy is unavailable" unless
            source.approval_mode && source.turn&.answering_user_public_id && round.tool_definitions && round.task.model

          model = round.task.model
          {
            model: model.fetch("model"), reasoning_effort: model["reasoning_effort"], reasoning_enabled: model["reasoning_enabled"],
            approval_mode: source.approval_mode,
            to: source.turn.answering_user_public_id,
            tool_names: round.tool_definitions.map { |entry| entry.dig("function", "name") || entry.fetch("name") },
            source_run_public_id: context.run_public_id, source_task_key: context.task_key,
            idempotency_key: "schedule:#{context.run_public_id}:#{context.task_key}",
          }
        end
      end
    end
  end
end

require_relative "schedules/read"
require_relative "schedules/manage"
