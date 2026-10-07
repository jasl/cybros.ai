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
    ServedTool = Data.define(:name, :effect_profile, :timeout_ms, :description, :input_schema) do
      def initialize(timeout_ms: nil, description: nil, input_schema: nil, **members)
        super(timeout_ms: timeout_ms, description: description, input_schema: input_schema, **members)
      end

      def to_h = super.compact
    end

    # One document an executor announced it can LOAD for a model:
    # a project's skill, an MCP prompt or resource
    # curated into the shape — `name` under the skill grammar and the
    # `description` a model reads to choose; nothing more, no kind.
    ServedDocument = Data.define(:name, :description)

    # One executor this principal may address. `environment` is the
    # announced snapshot, opaque and frozen — placement plus whatever the
    # machine chose to say, read by nobody here; `served_documents` the
    # documents it announced beside its tools.
    DiscoveredExecutor = Data.define(
      :public_id, :kind, :display_name, :status, :assignment_scope,
      :served_tools, :environment, :served_documents, :presence, :last_seen_at, :connected_at
    ) do
      def initialize(served_tools: [], environment: {}, served_documents: [], last_seen_at: nil,
                     connected_at: nil, **members)
        super(served_tools: served_tools, environment: environment, served_documents: served_documents,
          last_seen_at: last_seen_at, connected_at: connected_at, **members)
      end

      def runner? = kind == "runner"
      def tool_provider? = kind == "tool_provider"
      def online? = presence == "online"
      def tool_names = served_tools.map(&:name)
      def document_names = served_documents.map(&:name)
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
          assignment_scope: :string,
          served_tools: [:shapes, ServedTool],
          environment: :json_object_or_empty,
          served_documents: [:shapes, ServedDocument],
          presence: :string,
          last_seen_at: :optional_string,
          connected_at: :optional_string,
        },
        ServedTool => {
          name: :string,
          effect_profile: :json_object,
          timeout_ms: :optional_integer,
          description: :optional_string,
          input_schema: :optional_json_object,
        },
        # Both keys are what the kernel guarantees per entry: it refused
        # the announcement otherwise.
        ServedDocument => { name: :string, description: :string },
      }.freeze
    end
  end
end
