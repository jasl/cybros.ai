# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Runs::Tasks::RealtimesController < AgentAPI::V1::Workspaces::Runs::BaseController
  include AgentAPI::RealtimeSignaling

  # @oas_include
  # @summary Read realtimes
  # @tags Member, realtimes
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter task_key(path) [!String] Resource selector.
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRunsTasksRealtimesShow
  def show
    realtime = realtime_for(find_listable_loop(@workspace))
    return unless realtime

    render json: { realtime: realtime.projection }
  end

  # @oas_include
  # @summary Update realtimes
  # @tags Member, realtimes
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter task_key(path) [!String] Resource selector.
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRunsTasksRealtimesUpdate
  def update
    fields = signal_parameters
    run = find_listable_loop(@workspace)
    run.with_lock do
      realtime = realtime_for(run, lock: true)
      return unless realtime

      render_signal_outcome(realtime.answer(**fields), realtime)
    end
  end

  private

    def realtime_for(run, lock: false)
      scope = run.tasks.where(type: "Tasks::ToolTask")
      node = (lock ? scope.lock : scope).find_by!(node_key: params.fetch(:task_key))
      realtime = Executors::Realtime.new(node, credential: current_credential)
      return realtime if realtime.member?

      render_error(:not_authorized, "Refused: not_authorized", status: :forbidden)
      nil
    end
end
