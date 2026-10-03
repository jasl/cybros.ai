module Workspaces
  # The short transaction owner-authorized commands share, keeping the
  # global Workspace-before-User order.
  module Mutation
    Result = Data.define(:outcome, :workspace, :errors) do
      class << self
        def done(outcome, workspace)
          new(outcome: outcome, workspace: workspace, errors: nil)
        end

        def blocked(reason)
          new(outcome: reason, workspace: nil, errors: nil)
        end

        def invalid(record)
          new(outcome: :invalid, workspace: nil, errors: record.errors)
        end
      end
    end

    private

      # Workspace, then Humans by ascending id; the caller's `lock_version`
      # on the row makes the write the optimistic CAS.
      def with_mutation_locks(workspace, humans)
        workspace.with_lock do
          ids = humans.compact.uniq.map(&:id)
          rows = User.where(id: ids).order(:id).lock.index_by(&:id)

          yield workspace, rows
        end
      rescue ActiveRecord::StaleObjectError
        Result.blocked(:stale_object)
      end

      def disconnect_realtime_workspace_authority(workspace)
        RealtimeConnections::Disconnect.workspace_authority(workspace)
      end
  end
end
