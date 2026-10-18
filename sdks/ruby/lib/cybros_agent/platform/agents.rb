module CybrosAgent
  module Platform
    Agent = Data.define(:public_id, :handle, :display_name, :status, :agent_identifier,
      :named_agent_scope, :description, :derived_from_public_id)
    ApplicationConnection = Data.define(:executor_public_id, :owner_agent_public_id, :status,
      :credential_readiness, :presence, :last_seen_at, :connected_at)
    AgentDetail = Data.define(*Agent.members, :application_connection)
    AgentConfigurationSnapshot = Data.define(:agent, :configuration, :prompt_documents,
      :agent_updated_at, :measured_at)
    PrivateRunner = Data.define(:public_id, :display_name, :status, :registration_identifier,
      :assignment_scope, :assignment_agent_public_id)
    APIKey = Data.define(:public_id, :name, :note, :plane, :created_at, :last_used_at, :revoked_at, :usable)
    APIKeyGrant = Data.define(:api_key, :secret) do
      include Redacted

      def inspect = redacted(api_key:, hidden: %i[secret])
    end

    module AgentProjections
      include Api::WorkspaceProjections
      include Api::Fields

      AGENT_FIELDS = {
        public_id: :string, handle: :nullable_string, display_name: :string, status: :string,
        agent_identifier: :nullable_string, named_agent_scope: :nullable_string, description: :nullable_string,
        derived_from_public_id: :nullable_string,
      }.freeze

      SHAPES = {
        Agent => AGENT_FIELDS,
        ApplicationConnection => { executor_public_id: :string, owner_agent_public_id: :string, status: :string,
          credential_readiness: :string, presence: :string, last_seen_at: :nullable_string, connected_at: :nullable_string },
        AgentDetail => AGENT_FIELDS.merge(application_connection: [:optional_shape, ApplicationConnection]),
        AgentConfigurationSnapshot => { agent: [:shape, Agent], configuration: [:shape, Api::AgentConfiguration],
          prompt_documents: [:shapes, Api::PromptDocument], agent_updated_at: :string, measured_at: :string },
        Api::AgentConfiguration => Api::ProfileContext::SHAPES.fetch(Api::AgentConfiguration),
        Api::PromptDocument => Api::ConversationProjections::SHAPES.fetch(Api::PromptDocument),
        PrivateRunner => { public_id: :string, display_name: :string, status: :string,
          registration_identifier: :string, assignment_scope: :string, assignment_agent_public_id: :string },
        APIKey => { public_id: :string, name: :string, note: :nullable_string, plane: :string,
          created_at: :string, last_used_at: :nullable_string, revoked_at: :nullable_string, usable: :boolean },
        APIKeyGrant => { api_key: [:shape, APIKey], secret: :string },
      }.freeze
    end

    class Agents
      include AgentProjections

      PATH = "/api/v1/agents".freeze

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def list(after: nil, limit: nil)
        page(Agent, @dispatch.call(PATH, params: query(after:, limit:)), "agents")
      end

      def create(display_name:)
        shape(Agent, @dispatch.call(PATH, method: :post, success: 201,
          body: { "agent" => { "display_name" => display_name } }), "agent")
      end

      def agent(public_id)
        AgentContext.new(dispatch: @dispatch, path: "#{PATH}/#{path_segment(public_id, "public_id")}")
      end
    end

    class AgentContext
      include AgentProjections

      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = path.freeze
      end

      def fetch
        shape(AgentDetail, @dispatch.call(@path), "agent")
      end

      def configuration
        shape(AgentConfigurationSnapshot, @dispatch.call("#{@path}/configuration"))
      end

      def budgets
        Budgets.new(dispatch: @dispatch, path: "#{@path}/budgets")
      end

      def revoke_connection = transition("connection_revocation")
      def remove = transition("removal")
      def restore = transition("restoration")

      def api_keys
        APIKeys.new(dispatch: @dispatch, path: "#{@path}/api_keys", plane: "member")
      end

      def executor_api_keys
        APIKeys.new(dispatch: @dispatch, path: "#{@path}/executor/api_keys", plane: "executor_transport")
      end

      def private_runners
        PrivateRunners.new(dispatch: @dispatch, path: "#{@path}/private_runners")
      end

      private

        def transition(command)
          shape(Agent, @dispatch.call("#{@path}/#{command}", method: :post), "agent")
        end
    end

    class PrivateRunners
      include AgentProjections

      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = path.freeze
      end

      def list(after: nil, limit: nil)
        page(PrivateRunner, @dispatch.call(@path, params: query(after:, limit:)), "private_runners")
      end

      def create(display_name:)
        shape(PrivateRunner, @dispatch.call(@path, method: :post, success: 201,
          body: { "private_runner" => { "display_name" => display_name } }), "private_runner")
      end

      def runner(public_id)
        PrivateRunnerContext.new(dispatch: @dispatch, path: "#{@path}/#{path_segment(public_id, "public_id")}")
      end
    end

    class PrivateRunnerContext
      include AgentProjections

      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = path.freeze
      end

      def fetch
        shape(PrivateRunner, @dispatch.call(@path), "private_runner")
      end

      def api_keys
        APIKeys.new(dispatch: @dispatch, path: "#{@path}/api_keys", plane: "executor_transport")
      end
    end

    # Member, Agent executor, and private Runner keys have one wire shape.
    # The selected resource fixes the plane; a malformed reply cannot relabel it.
    class APIKeys
      include AgentProjections

      def initialize(dispatch:, path:, plane:)
        @dispatch = dispatch
        @path = path.freeze
        @plane = plane
      end

      def list(after: nil, limit: nil)
        result = page(APIKey, @dispatch.call(@path, params: query(after:, limit:)), "api_keys")
        result.items.each { |key| validate_plane(key) }
        result
      end

      def create(name:, note: omitted_field)
        grant = shape(APIKeyGrant, @dispatch.call(@path, method: :post, success: 201,
          body: { "api_key" => fields(name:, note:) }))
        validate_plane(grant.api_key)
        grant
      end

      def revoke(public_id)
        @dispatch.call("#{@path}/#{path_segment(public_id, "public_id")}/revocation", method: :post, success: 204)
        nil
      end

      private

        def validate_plane(key)
          raise Api::MalformedResponse, "unexpected API key plane" unless key.plane == @plane
        end
    end
  end
end
