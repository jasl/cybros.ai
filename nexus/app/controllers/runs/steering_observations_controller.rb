class Runs::SteeringObservationsController < Runs::Steers::BaseController
  def show
    # Native cancellation posts need an Origin even when this page has a return target.
    response.headers["Referrer-Policy"] = "same-origin"
    @input_public_id = params.expect(:input_public_id).to_s.downcase
    raise APIErrors::ParameterInvalid, :input_public_id unless Input.uuid_shaped?(@input_public_id)
    @observation = Run::SteeringObservation.new(run: @run, input_public_id: @input_public_id)
    @candidate_read = original_candidate
  end

  private

    def original_candidate
      ::Conversations::Reader.new(@conversation, user: acting_user).variant(
        turn_public_id: @run.turn.public_id, variant_public_id: @run.variant.public_id)
    rescue ActiveRecord::RecordNotFound
      nil
    end
end
