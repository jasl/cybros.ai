# Subscribe through the same visibility query as REST: deleted conversations
# and access level `none` both reject like absence. Conversation ACL changes
# do not recheck or disconnect existing subscriptions. Workspace authority
# changes separately request member-connection disconnection with reconnect,
# so a reconnect must pass the workspace and conversation checks again.
class AgentAPI::V1::ConversationEventsChannel < AgentAPI::V1::EventsChannel
  private

    def find_host(workspace, user)
      Conversation.visible_to(user, workspace: workspace)
        .find_by(public_id: params[:conversation_id])
    end
end
