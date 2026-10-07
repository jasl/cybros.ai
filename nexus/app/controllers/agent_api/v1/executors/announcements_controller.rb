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
    outcome = current_credential.task_executor.announce(tools: tools, environment: environment, documents: documents)

    if outcome.accepted?
      render json: AgentAPI::ExecutorPresenter.description(outcome.executor, measured_at: Time.current,
        live_server_ids: NexusServer.live_ids)
    elsif outcome.outcome == :invalid
      # The bounded-JSON refusal, the family's `validation_failed`.
      render_error(:validation_failed, outcome.executor.errors.full_messages.to_sentence,
        status: :unprocessable_content)
    else
      # `reserved_namespace` and `invalid_announcement` carry the model's
      # detail naming the entry and field.
      render_refusal(outcome.outcome, outcome.detail)
    end
  end

  private

    # The list is opaque by contract and read from the request body as
    # sent; the entry rules are the model's (Nexus::ToolAnnouncements). A
    # missing list is the caller's 400; a present non-list is refused there.
    def tools
      tools = request.request_parameters["tools"]
      raise ActionController::ParameterMissing, :tools if tools.nil?

      tools
    end

    # Opaque and optional: absent is "none", which the row stores as `{}`.
    def environment = request.request_parameters["environment"]

    # Optional and read as sent: absent is "none", which the row stores as
    # `[]`; the entry rules are the model's (Nexus::ToolAnnouncements).
    def documents = request.request_parameters["documents"]
end
