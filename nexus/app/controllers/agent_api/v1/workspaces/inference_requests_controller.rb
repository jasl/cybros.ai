# One resource with the workload in the payload. Create is receipt-idempotent
# and asynchronous by contract (202; completion by polling, replay or the
# cable); refusals come typed from the domain — the symbol is the error code.
class AgentAPI::V1::Workspaces::InferenceRequestsController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include AgentAPI::InferenceRequestInputParameters

  def index
    scope = workload_scope(
      InferenceRequest.where(workspace_id: @workspace.id).listable.includes(:model_invocation)
    )
    page = keyset_page(scope, columns: { public_id: :uuid })

    render json: {
      inference_requests: page.records.map { |inference_request| AgentAPI::InferenceRequestPresenter.basic(inference_request) },
      pagination: { next_after: page.next_after },
    }
  end

  def show
    inference_request = find_listable_inference_request(@workspace)

    render json: { inference_request: AgentAPI::InferenceRequestPresenter.full(inference_request) }
  end

  def create
    key = required_idempotency_key
    return if performed?

    fields = create_fields
    result = InferenceRequests::Create.call(
      command: InferenceRequests::Create::Command.new(
        workspace: @workspace,
        creating_user: acting_user,
        workload: fields[:workload],
        submitted: submitted_inference_request_selection(fields),
        configuration: plain_inference_request_configuration(fields),
        input: raw_inference_request_input(:inference_request),
        upload_public_ids: Array(fields[:upload_public_ids]),
        billing_subject: fields[:billing_subject],
        idempotency_key: key
      ),
      port: ModelSelection::Resolver.new
    )
    render_create_result(@workspace, result)
  end

  # Terminal-only tombstone: running work refuses 409 — cleanup never cancels
  # on the caller's behalf; a tombstoned row was already absent, so a second
  # DELETE is the listable scope's 404.
  def destroy
    inference_request = find_listable_inference_request(@workspace)
    return unless authorize_writable(@workspace)

    result = InferenceRequests::Tombstone.call(inference_request: inference_request)
    if result.accepted?
      head :no_content
    else
      render_refusal(result.outcome)
    end
  end

  private

    def workload_scope(scope)
      case params[:workload]
      when nil then scope
      when *Nexus::ModelWorkloads::ALL then scope.where(workload: params[:workload])
      else raise APIErrors::ParameterInvalid, :workload
      end
    end

    def find_listable_inference_request(workspace)
      InferenceRequest.where(workspace_id: workspace.id).listable
        .find_by!(public_id: params.fetch(:public_id))
    end

    def create_fields
      params.expect(inference_request: [
        :workload, :billing_subject,
        { model: %i[model reasoning_effort reasoning_enabled], configuration: {}, upload_public_ids: [] },
      ])
    end

    def render_create_result(workspace, result)
      case result.outcome
      when :created
        # The admission wake: the recurring pass is the floor, this is the
        # latency. Rails defers the enqueue to the surrounding commit.
        ModelInvocations::AdmitQueuedWorkJob.perform_later
        render json: { inference_request: accepted_projection(workspace, result) }, status: :accepted
      when :replayed
        render json: { inference_request: accepted_projection(workspace, result) }
      when :idempotency_mismatch
        render_refusal(:idempotency_envelope_mismatch)
      when :refused
        # The refusal symbol IS the error code: the domain's typed vocabulary
        # crosses the wire unlaundered, so a caller can branch on it and an
        # operator can grep for it.
        render_refusal(result.refusal)
      else
        raise "unmapped create outcome: #{result.outcome}"
      end
    end

    def accepted_projection(workspace, result)
      inference_request = InferenceRequest.where(workspace_id: workspace.id).listable
        .find_by!(public_id: result.accepted.fetch("inference_request_public_id"))
      AgentAPI::InferenceRequestPresenter.full(inference_request)
    end
end
