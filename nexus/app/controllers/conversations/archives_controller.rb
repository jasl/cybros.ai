class Conversations::ArchivesController < Conversations::BaseController
  before_action :require_writable_conversation

  def new
  end

  def create
    result = ::Conversations::Archive.call(conversation: @conversation)
    if result.accepted?
      redirect_to conversation_path(@conversation, return_to: work_return_path(workspace_conversations_path(@conversation.workspace))),
        status: :see_other, notice: t("conversation_management.archive.saved")
    else
      @form_errors = [t("conversation_management.refusals.#{result.outcome}")]
      render :new, status: Nexus::FamilyErrors.status_for(result.outcome) ||
        AgentAPI::V1::BaseController::REFUSAL_STATUSES.fetch(result.outcome, :unprocessable_entity)
    end
  end
end
