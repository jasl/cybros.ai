class Conversations::ChildrenController < Work::BaseController
  def index
    @conversation = find_visible_conversation(:conversation_id)
    @heading = t("conversation_console.children")
    scope = Conversation.visible_to(acting_user, workspace: @conversation.workspace)
      .where(parent_conversation_id: @conversation.id)
    @conversations_pagy, @conversations = pagy(:offset,
      scope.includes(:workspace, :answering_user, :active_turn).order(last_activity_at: :desc, public_id: :desc), limit: 20)
    render "conversations/related"
  end
end
