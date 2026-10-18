module CybrosAgent
  module Platform
    # Management facts are separate from execution discovery. A Human may
    # inspect their private Runner without being its execution principal.
    ManagedRunner = Data.define(:public_id, :kind, :display_name, :status, :manager_public_id,
      :assignment_scope, :assignment_agent_public_id, :credential_readiness, :eligible_for_current_user,
      :presence, :last_seen_at, :connected_at, :registered_at)
    ManagedRunnerDetail = Data.define(*ManagedRunner.members, :served_tools, :served_documents, :environment)
    ManagedRunnerPage = Data.define(:items, :next_after, :measured_at)
    ManagedRunnerSnapshot = Data.define(:runner, :measured_at)

    module ManagedRunnerProjections
      include Api::WorkspaceProjections
      include Api::ExecutorProjections
      include Api::Fields

      RUNNER_FIELDS = {
        public_id: :string, kind: :string, display_name: :string, status: :string, manager_public_id: :string,
        assignment_scope: :string, assignment_agent_public_id: :nullable_string, credential_readiness: :string,
        eligible_for_current_user: :boolean, presence: :string, last_seen_at: :nullable_string,
        connected_at: :nullable_string, registered_at: :string,
      }.freeze

      SHAPES = {
        ManagedRunner => RUNNER_FIELDS,
        ManagedRunnerDetail => RUNNER_FIELDS.merge(served_tools: [:shapes, Api::ServedTool],
          served_documents: [:shapes, Api::ServedDocument], environment: :json_object),
        ManagedRunnerPage => { items: [:shapes, ManagedRunner, "runners"],
          next_after: [:nullable_string, "pagination", "next_after"], measured_at: :string },
        ManagedRunnerSnapshot => { runner: [:shape, ManagedRunnerDetail], measured_at: :string },
      }.freeze
    end

    class ManagedRunners
      include ManagedRunnerProjections

      PATH = "/api/v1/runners".freeze

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def list(after: nil, limit: nil, kind: nil, status: nil, order: nil)
        shape(ManagedRunnerPage, @dispatch.call(PATH, params: query(after:, limit:, kind:, status:, order:)))
      end

      def fetch(public_id)
        shape(ManagedRunnerSnapshot, @dispatch.call("#{PATH}/#{path_segment(public_id, "public_id")}"))
      end
    end
  end
end
