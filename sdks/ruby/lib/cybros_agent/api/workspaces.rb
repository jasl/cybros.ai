module CybrosAgent
  module Api
    # The member plane's Workspace collection: keyset-listed reads, receipt-idempotent
    # creation, and the singular fetch. Managing one row is WorkspaceContext's job, reached
    # through Client#workspace.
    class Workspaces
      include WorkspaceProjections
      include Fields

      Created = Data.define(:workspace, :replayed) do
        def replayed? = replayed
      end

      PATH = "/agent_api/v1/workspaces".freeze

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      # The default state scope is live; `state: "archived"` reads the recycle
      # bin. Nexus applies principal-sensitive dedication visibility and
      # resolves `true` against the current Agent — the SDK never learns the
      # identifier.
      def list(state: nil, dedicated_to_current_agent: nil, after: nil, limit: nil, order: nil)
        params = query(state:, dedicated_to_current_agent:, after:, limit:, order:)
        page(WorkspaceSummary, @dispatch.call(PATH, params: params), "workspaces")
      end

      # Creation demands the caller's own Idempotency-Key — the SDK never
      # silently mints one. Omitted keywords send no field;
      # explicit nil travels as JSON null for the server to judge.
      def create(name:, idempotency_key:, access_mode: UNSET, metadata: UNSET)
        required_string(idempotency_key, "idempotency_key")
        body = fields(name:, access_mode:, metadata:)

        answer = @dispatch.call_accepting(
          PATH,
          method: :post,
          body: { "workspace" => body },
          headers: { "Idempotency-Key" => idempotency_key },
          success: 201
        )
        Created.new(workspace: shape(Workspace, answer.body, "workspace"), replayed: answer.replayed)
      end

      def fetch(public_id)
        shape(Workspace, @dispatch.call("#{PATH}/#{path_segment(public_id, "public_id")}"), "workspace")
      end
    end
  end
end
