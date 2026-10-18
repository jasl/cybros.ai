module ConversationsHelper
  def conversation_title(conversation)
    conversation.title.presence || t("conversation_console.untitled")
  end
end
