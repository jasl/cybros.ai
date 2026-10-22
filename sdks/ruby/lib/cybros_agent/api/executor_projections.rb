module CybrosAgent
  module Api
    # AUTHORIZED DISCOVERY: what the kernel will let this
    # credential address, with the declaration facts each machine
    # announced — the feeder of a remote runner's declaration and of
    # `runner_executor_public_id` at create. The listing is filtered by
    # ELIGIBILITY server-side, so a row here is one this principal may
    # bind; presence is display, never a reason to choose.

    # One announced entry, as the kernel stored it: `name` and
    # `effect_profile` are guaranteed, the rest is what the machine chose
    # to say about itself (`description` and `input_schema` are the
    # declaration keys an agent reads to author a declaration from a
    # runner it did not load).
    ServedTool = Data.define(:name, :effect_profile, :timeout_ms, :description, :input_schema, :mcp) do
      def initialize(timeout_ms: nil, description: nil, input_schema: nil, mcp: nil, **members)
        super(timeout_ms: timeout_ms, description: description, input_schema: input_schema, mcp: mcp, **members)
      end

      def to_h = super.compact
    end

    # One document an executor announced it can LOAD for a model:
    # a project's skill, an MCP prompt or resource
    # curated into the shape — `name` under the skill grammar and the
    # `description` a model reads to choose; nothing more, no kind.
    ServedDocument = Data.define(:name, :description)

    ExecutorService = Data.define(:tools, :documents, :environment)
    ExecutorServices = Data.define(:agent, :runner, :tool_provider) do
      def for(role) = public_send(role)
    end

    # Registration kind is identity; services describe the roles it offers.
    DiscoveredExecutor = Data.define(
      :public_id, :kind, :display_name, :status, :assignment_scope, :agent_public_id,
      :service_roles, :services, :presence, :last_seen_at, :connected_at
    ) do
      def provides?(role) = service_roles.include?(role.to_s)
      def online? = presence == "online"
      def tools_for(role) = services.for(role)&.tools || []
      def documents_for(role) = services.for(role)&.documents || []
      def environment_for(role) = services.for(role)&.environment || {}
      def tool_names(role:) = tools_for(role).map(&:name)
      def document_names(role:) = documents_for(role).map(&:name)
    end

    # The discovery document's wire grammar, read strictly where the kernel
    # guarantees a member and leniently where a machine may have said nothing.
    module ExecutorProjections
      include Parsing

      SHAPES = {
        DiscoveredExecutor => {
          public_id: :string,
          kind: :string,
          display_name: :optional_string,
          status: :string,
          assignment_scope: :optional_string,
          agent_public_id: :optional_string,
          service_roles: :string_list,
          services: [:shape, ExecutorServices],
          presence: :string,
          last_seen_at: :optional_string,
          connected_at: :optional_string,
        },
        ExecutorServices => {
          agent: [:optional_shape, ExecutorService],
          runner: [:optional_shape, ExecutorService],
          tool_provider: [:optional_shape, ExecutorService],
        },
        ExecutorService => {
          tools: [:shapes, ServedTool], documents: [:shapes, ServedDocument], environment: :json_object,
        },
        ServedTool => {
          name: :string,
          effect_profile: :json_object,
          timeout_ms: :optional_integer,
          description: :optional_string,
          input_schema: :optional_json_object,
          mcp: :optional_json_object,
        },
        # Both keys are what the kernel guarantees per entry: it refused
        # the announcement otherwise.
        ServedDocument => { name: :string, description: :string },
      }.freeze
    end
  end
end
