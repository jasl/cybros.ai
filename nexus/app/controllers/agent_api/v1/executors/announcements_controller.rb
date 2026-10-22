# PUT /agent_api/v1/executor/announcement — what this executor SERVES, for
# delivery only: a whole replacement of the served-tools list, the
# environment document and the documents it can load for a model that the
# executor itself makes on the transport plane, answered with the same
# description GET /executor renders. Consumed by addressing alone; it never
# shapes a round's tools list — the declaration is the model's fact — except
# the `skill` entry's PRESENCE (omitted at the wire on the empty merge;
# never its bytes).
class AgentAPI::V1::Executors::AnnouncementsController < AgentAPI::V1::BaseController
  serves_plane :executor_transport

  def update
    outcome = current_credential.executor.announce(services: services)

    if outcome.accepted?
      render json: AgentAPI::ExecutorPresenter.description(outcome.value, measured_at: Time.current,
        live_server_ids: NexusServer.live_ids)
    elsif outcome.outcome == :invalid
      # The bounded-JSON refusal, the family's `validation_failed`.
      render_error(:validation_failed, outcome.value.errors.full_messages.to_sentence,
        status: :unprocessable_content)
    else
      # `reserved_namespace` and `invalid_announcement` carry the model's
      # detail naming the entry and field.
      render_refusal(outcome.outcome, outcome.detail)
    end
  end

  private

    # Service entry grammar and opaque tool/environment payloads belong to the
    # announcement boundary; a missing envelope is the HTTP parameter error.
    def services
      document = request.request_parameters["services"]
      raise ActionController::ParameterMissing, :services if document.nil?

      document
    end
end
