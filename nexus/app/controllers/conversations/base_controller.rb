class Conversations::BaseController < Work::BaseController
  before_action :set_conversation

  private

    def set_conversation
      @conversation = find_visible_conversation(:conversation_id)
    end

    def require_writable_conversation
      unless @conversation.writable_by?(acting_user)
        render_error(:not_authorized, t("conversation_reading.not_writable"), status: :forbidden)
      end
    end
end
