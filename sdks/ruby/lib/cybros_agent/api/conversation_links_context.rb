module CybrosAgent
  module Api
    ConversationLinkEndpoint = Data.define(:conversation_public_id, :agent_public_id)
    ConversationLink = Data.define(:public_id, :workspace_public_id, :endpoint, :peer,
      :state, :created_at, :closed_at, :close_reason)

    # A link grants messaging between fixed endpoints, never peer history access.
    class ConversationLinksContext
      include WorkspaceProjections
      include Fields

      SHAPES = {
        ConversationLinkEndpoint => { conversation_public_id: :string, agent_public_id: :string },
        ConversationLink => {
          public_id: :string, workspace_public_id: :string,
          endpoint: [:shape, ConversationLinkEndpoint], peer: [:shape, ConversationLinkEndpoint],
          state: :string, created_at: :string, closed_at: :optional_string, close_reason: :optional_string,
        },
      }.freeze

      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = path
      end

      def list(state: nil, after: nil, limit: nil)
        body = @dispatch.call(@path, params: query(state:, after:, limit:))
        Page.new(items: shapes(ConversationLink, body, "links"), next_after: nullable_string(body, "next_after"))
      end

      def fetch(public_id)
        shape(ConversationLink, @dispatch.call(link_path(public_id)), "link")
      end

      def create(agent_public_id:, peer_conversation_public_id:, peer_agent_public_id:, idempotency_key:)
        body = { "link" => {
          "agent_public_id" => required_string(agent_public_id, "agent_public_id"),
          "peer_conversation_public_id" => required_string(peer_conversation_public_id, "peer_conversation_public_id"),
          "peer_agent_public_id" => required_string(peer_agent_public_id, "peer_agent_public_id"),
        } }
        answer = @dispatch.call_accepting(@path, method: :post, body: body,
          headers: { "Idempotency-Key" => required_string(idempotency_key, "idempotency_key") }, success: [200, 201])
        Created.new(link: shape(ConversationLink, answer.body, "link"), replayed: answer.replayed)
      end

      def close(public_id)
        shape(ConversationLink, @dispatch.call("#{link_path(public_id)}/closure", method: :post), "link")
      end

      private

        def link_path(public_id) = "#{@path}/#{path_segment(public_id, "public_id")}"

      Created = Data.define(:link, :replayed) do
        def replayed? = replayed
        def public_id = link.public_id
      end
    end
  end
end
