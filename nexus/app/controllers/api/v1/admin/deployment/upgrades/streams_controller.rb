# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::Deployment::Upgrades::StreamsController < API::V1::Admin::Deployment::Upgrades::BaseController
  include ActionController::Live

  # @oas_include
  # @parameter Last-Event-ID(header) [String] Last observed event cursor.
  # @summary Read streams
  # @tags Platform, streams
  # @parameter upgrade_id(path) [!String] Resource selector.
  # @parameter after(query) [String] Opaque continuation cursor.
  # @parameter limit(query) [Integer] Page size; the resource reference specifies its bound.
  # @parameter order(query) [String] Ordering direction.
  # @response_ref (200) #/components/responses/ApiV1AdminDeploymentUpgradesStreamsShow
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  def show
    operation_id = params[:upgrade_id].to_s
    cursor = deployment_cursor || request.headers["Last-Event-ID"]&.to_s
    initial = deployment_client.log(operation_id: operation_id, cursor: cursor)
    return deployment_json(initial, resource: :log) unless initial.success?

    response.headers["Content-Type"] = "text/event-stream"
    response.headers["X-Accel-Buffering"] = "no"
    stream = ActionController::Live::SSE.new(response.stream)
    progress = Deployments::Progress.new(client: deployment_client,
      session: Current.session, access_token: Current.access_token)
    progress.stream(operation_id: operation_id, cursor: cursor, initial: initial) do |event, value|
      case event
      when :progress
        stream.write(API::DeploymentPresenter.log(value), event: "deployment.progress.v1", id: value.next_cursor)
      when :error
        stream.write(API::DeploymentPresenter.error(value), event: "deployment.error.v1")
      else
        raise ArgumentError, "Unknown deployment observation"
      end
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    # Leaving the page closes observation only; the updater keeps executing.
  ensure
    stream&.close
  end
end
