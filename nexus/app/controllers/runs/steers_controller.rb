class Runs::SteersController < Runs::Steers::BaseController
  def index
    @inputs_pagy, @inputs = pagy(:offset,
      @run.steering_inputs.where(expected_steering_run_public_id: @run.public_id)
        .includes(:authoring_user, content_bodies: { content_body_entries: :content_fragment })
        .order(:queue_position, :id), limit: 20)
  end
end
