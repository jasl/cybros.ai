class Conversations::CancellationsController < Conversations::BaseController
  before_action :require_writable_conversation

  def new
  end

  def create
    result = ::Conversations::Turns::Cancel.call(::Conversations::Turns::Cancel::Command.new(
      conversation: @conversation, acting_user: acting_user
    ))

    if result.accepted?
      redirect_to work_return_path(conversation_path(@conversation)), status: :see_other,
        notice: t("conversation_cancellation.accepted")
    elsif result.outcome == :not_running
      @not_running = true
      render :new, status: :conflict
    else
      render_error(result.outcome, t("conversation_cancellation.refusals.#{result.outcome}"),
        status: AgentAPI::V1::BaseController::REFUSAL_STATUSES.fetch(result.outcome, :unprocessable_entity))
    end
  end
end
