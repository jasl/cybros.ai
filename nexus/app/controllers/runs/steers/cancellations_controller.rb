class Runs::Steers::CancellationsController < Runs::Steers::BaseController
  before_action :require_writable_conversation

  def create
    input = targeted_input
    return redirect_to observation_path(params.fetch(:steer_id)), status: :see_other unless input

    result = ::Conversations::Inputs::Destroy.call(::Conversations::Inputs::Destroy::Command.new(
      host: @conversation, input_public_id: input.public_id, acting_user: acting_user
    ))
    if result.accepted?
      redirect_to observation_path(input.public_id), status: :see_other, notice: t("run_steering.canceled")
    elsif result.outcome == :not_found
      redirect_to observation_path(input.public_id), status: :see_other
    else
      render_steer_failure(result)
    end
  end
end
