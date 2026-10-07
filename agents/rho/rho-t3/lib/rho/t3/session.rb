require "securerandom"

module Rho
  module T3
    class Session
      attr_reader :records, :context

      def initialize(member_plane:, context: Rho::Runner::ExecutionContext.current)
        @context = context
        unless context&.conversation_public_id && context.run_public_id && context.task_key
          raise Error, "coding delegation requires a conversation-owned task"
        end
        context.raise_if_cancelled!
        plane = member_plane.call(host_public_id: context.conversation_public_id, workspace_public_id: context.workspace_public_id)
        raise Error, "coding delegation requires a member connection" unless plane

        @workspace = plane.client.workspace(plane.workspace_public_id)
        @records = Records.new(store: @workspace.conversation(context.conversation_public_id).store_entries,
          conversation: context.conversation_public_id)
      end

      def key = "#{context.run_public_id}:#{context.task_key}"
      def owner = { "run" => context.run_public_id, "task" => context.task_key }

      def active?(owner)
        task = @workspace.runs.run(owner.fetch("run")).task(owner.fetch("task"))
        task.task.live?
      end

      def cancel(owner)
        @workspace.runs.run(owner.fetch("run")).tasks_context(owner.fetch("task")).cancel
      rescue CybrosAgent::Api::NotFound
        nil
      rescue CybrosAgent::Api::Conflict => error
        case error.code
        when "already_terminal"
          nil
        when "not_adjudicable"
          raise if active?(owner)
        else
          raise
        end
      end
    end
  end
end
