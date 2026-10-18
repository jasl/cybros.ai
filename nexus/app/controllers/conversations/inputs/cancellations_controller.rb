class Conversations::Inputs::CancellationsController < Conversations::Inputs::BaseController
  def create
    public_id = params.fetch(:input_id)
    input = @conversation.inputs.find_by(public_id: public_id)
    # This page manages pending/blocked inputs; held steers keep their own controls.
    raise ActiveRecord::RecordNotFound if input && !helpers.conversation_input_cancellable?(input)

    result = ::Conversations::Inputs::Destroy.call(::Conversations::Inputs::Destroy::Command.new(
      host: @conversation, input_public_id: public_id, acting_user: acting_user
    ))
    if result.accepted?
      redirect_to work_return_path(conversation_inputs_path(@conversation)), status: :see_other,
        notice: t("conversation_inputs.canceled")
    elsif result.outcome == :not_found && @conversation.timeline.materialized_entry(input_public_id: public_id)
      redirect_to conversation_input_path(@conversation, public_id, return_to: return_path(params[:return_to])), status: :see_other,
        notice: t("conversation_inputs.already_materialized")
    else
      render_error(result.outcome, helpers.conversation_input_refusal(result.outcome),
        status: AgentAPI::V1::BaseController::REFUSAL_STATUSES.fetch(result.outcome, :unprocessable_entity))
    end
  end
end
