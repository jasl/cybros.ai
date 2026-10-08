module AgentAPI
  # Working, archived and child lists share the same order and projection.
  module ConversationListing
    ORDER_COLUMNS = {
      "public_id" => { public_id: :uuid }.freeze,
      "last_activity_at" => { last_activity_at: :timestamp, public_id: :uuid }.freeze,
    }.freeze

    private

      def render_conversation_list(scope)
        order_by = params[:order_by].presence || "public_id"
        columns = ORDER_COLUMNS.fetch(order_by.to_s) { raise APIErrors::ParameterInvalid, :order_by }
        page = keyset_page(scope, columns: columns)

        render json: {
          conversations: ConversationPresenter.basic_collection(
            page.records, acting_user: acting_user, workspace: @workspace
          ),
          pagination: { next_after: page.next_after },
        }
      end
  end
end
