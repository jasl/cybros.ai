class AgentAPI::V1::Workspaces::Conversations::LinksController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def index
    conversation = find_listable_conversation(@workspace)
    scope = ConversationLink.for_conversation(conversation)
    state = params.fetch(:state, "active")
    raise APIErrors::ParameterInvalid, :state unless %w[active closed all].include?(state)
    scope = scope.where(closed_at: nil) if state == "active"
    scope = scope.where.not(closed_at: nil) if state == "closed"
    page = keyset_page(scope.includes(:workspace, :first_conversation, :second_conversation, :first_agent, :second_agent),
      columns: { created_at: :timestamp, public_id: :uuid })
    render json: { links: page.records.map { |link| ::Conversations::LinkProjection.call(link, conversation: conversation) },
      next_after: page.next_after }
  end

  def show
    conversation = find_listable_conversation(@workspace)
    link = ConversationLink.for_conversation(conversation).find_by!(public_id: params.fetch(:public_id))
    render json: { link: ::Conversations::LinkProjection.call(link, conversation: conversation) }
  end

  def create
    conversation = find_listable_conversation(@workspace)
    return unless authorize_writable(conversation)
    key = required_idempotency_key
    return if performed?
    fields = params.require(:link).permit(:agent_public_id, :peer_conversation_public_id, :peer_agent_public_id).to_h
    fields.values_at("agent_public_id", "peer_conversation_public_id", "peer_agent_public_id").each do |value|
      raise APIErrors::ParameterInvalid, :link unless Input.uuid_shaped?(value)
    end
    result = ConversationCommandReceipt::Idempotent.call(account: current_account, workspace: @workspace,
      acting_user: acting_user, operation: :link_create, idempotency_key: key, host: conversation,
      request_digest: ConversationCommandReceipt.digest_for(operation: :link_create, envelope: fields)) do
      peer = Conversation.visible_to(acting_user, workspace: @workspace).find_by!(public_id: fields.fetch("peer_conversation_public_id"))
      agents = User.members.where(account_id: current_account.id)
      created = ::Conversations::Links::Create.call(conversation: conversation,
        agent: agents.find_by!(public_id: fields.fetch("agent_public_id")), peer_conversation: peer,
        peer_agent: agents.find_by!(public_id: fields.fetch("peer_agent_public_id")), acting_user: acting_user)
      next created unless created.accepted?
      ConversationCommandReceipt::Idempotent::Success.new(
        status: created.value.previously_new_record? ? 201 : 200,
        body: { link: ::Conversations::LinkProjection.call(created.value, conversation: conversation) }, host: conversation)
    end
    render_idempotent_outcome(result)
  end

  private

    def list_limit = limit_param(default: 50, max: 100)
    def list_direction = :desc
end
