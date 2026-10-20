class Settings::McpConnectionsController < Settings::McpConnections::BaseController
  skip_before_action :load_connection, only: [:index, :new, :create]

  def index
    @pagy, @connections = pagy(Current.user.mcp_connections.order(:name, :id), limit: 25)
  end

  def new
    @connection = Current.user.mcp_connections.build(auth_type: "bearer")
  end

  def show
    if @connection.auth_type == "oauth"
      # Turbo first fetches this page, then reloads it as a full document.
      flash.keep if request.get? && Turbo.current_request_id.present?
    end
  end

  def create
    @connection = Current.user.mcp_connections.build(create_connection_attributes)
    finish_change(@connection.save_owned, template: :new)
  end

  def update
    fields = connection_update_fields
    finish_change(@connection.revise(attributes: connection_update_attributes(fields),
      expected_lock_version: expected_version(fields)))
  end
end
