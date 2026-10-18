module CybrosAgent
  module Api
    # Readable root history across workspaces. Filtering precedes pagination;
    # each result carries the workspace required for its singular handle.
    class Conversations
      include ConversationProjections
      include Fields

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def list(after: nil, limit: nil, order: nil, order_by: nil, archived: nil,
               answering_user_public_id: nil, metadata_key: nil, metadata_value: nil)
        params = query(after:, limit:, order:, order_by:, archived:,
          answering_user_public_id:, metadata_key:, metadata_value:)
        page(ConversationSummary, @dispatch.call("/agent_api/v1/conversations", params: params), "conversations")
      end
    end
  end
end
