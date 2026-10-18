class Runs::Steers::BaseController < Runs::BaseController
  private

    def set_run
      super
      raise ActiveRecord::RecordNotFound if @run.standalone? || @run.conversation.side?

      @conversation = @run.conversation
    end

    def require_writable_conversation
      unless @conversation.writable_by?(acting_user)
        render_error(:not_authorized, t("conversation_reading.not_writable"), status: :forbidden)
      end
    end

    def targeted_input
      input = @conversation.inputs.find_by(public_id: params.fetch(:steer_id))
      if input && (!input.steering? || input.expected_steering_run_public_id != @run.public_id)
        raise ActiveRecord::RecordNotFound
      end
      input
    end

    def observation_path(public_id)
      run_steering_observation_path(@run, input_public_id: public_id, return_to: return_path(params[:return_to]))
    end

    def steer_failure(result)
      code = result.outcome
      @form_errors = result.invalid? ? result.errors.full_messages :
        [t("run_steering.refused", reason: helpers.conversation_input_refusal(code))]
      @form_status = Nexus::FamilyErrors.status_for(code) ||
        AgentAPI::V1::BaseController::REFUSAL_STATUSES.fetch(code, :unprocessable_entity)
    end

    def render_steer_failure(result)
      steer_failure(result)
      render_error(result.outcome, @form_errors.to_sentence, status: @form_status)
    end
end
