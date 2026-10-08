class API::V1::Admin::Deployment::Upgrades::StreamsController < API::V1::Admin::Deployment::Upgrades::BaseController
  include ActionController::Live

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
