class WorkspacesController < Workspaces::BaseController
  PAGE_SIZE = 10

  before_action :ensure_manageable, only: [:edit, :update]

  def index
    scope = Workspace.data_accessible_to(Current.user)
    @archived_tab = params[:tab] == "archived"
    scope = @archived_tab ? scope.where(state: %w[archiving archived]) : scope.live
    @workspaces_pagy, @workspaces = pagy(
      :offset,
      scope.includes(:owner).order(:name, :id),
      limit: PAGE_SIZE
    )
  end

  def show
    @workspace = workspace
  end

  def new
    @submitted_name = ""
    @submitted_access_mode = "private"
  end

  def create
    submitted = params.expect(workspace: [:name, :access_mode])
    @submitted_name = submitted[:name].to_s
    @submitted_access_mode = submitted.fetch(:access_mode, "private").to_s
    result = ::Workspaces::Create.call(
      creator: Current.user,
      name: @submitted_name,
      access_mode: @submitted_access_mode
    )

    case result.outcome
    when :created
      redirect_to workspace_path(result.workspace), status: :see_other, notice: t("workspaces.create.created")
    when :invalid
      @name_errors = result.errors.full_messages_for(:name)
      render :new, status: :unprocessable_entity
    when :invalid_access_mode
      @access_mode_errors = [t("workspaces.create.invalid_access_mode")]
      render :new, status: :unprocessable_entity
    when :not_workspace_owner
      redirect_to workspaces_path, alert: t("workspaces.not_owner")
    else
      raise "unmapped workspace outcome: #{result.outcome.inspect}"
    end
  end

  def edit
    @workspace = workspace
    @submitted_name = @workspace.name
    @submitted_metadata = JSON.pretty_generate(@workspace.metadata)
    @submitted_lock_version = @workspace.lock_version
  end

  def update
    @workspace = workspace
    submitted = params.expect(workspace: [:name, :metadata, :lock_version])
    @submitted_name = submitted[:name].to_s
    @submitted_metadata = submitted.key?(:metadata) ?
      submitted[:metadata].to_s :
      JSON.pretty_generate(@workspace.metadata)
    @submitted_lock_version = submitted[:lock_version].to_i
    metadata_input = parse_metadata(@submitted_metadata)

    if metadata_input[:error]
      @metadata_errors = [metadata_input[:error]]
      refresh_workspace_and_render_edit(status: :unprocessable_entity)
    else
      update_workspace(submitted, metadata_input[:value])
    end
  end

  private

    def parse_metadata(value)
      { value: JSON.parse(value), error: nil }
    rescue JSON::ParserError
      { value: nil, error: t("workspaces.update.metadata_invalid_json") }
    end

    def update_workspace(submitted, metadata)
      changes = {
        workspace: @workspace,
        by: Current.user,
        lock_version: @submitted_lock_version,
        name: @submitted_name,
      }
      changes[:metadata] = metadata if submitted.key?(:metadata)

      result = ::Workspaces::Update.call(**changes)

      case result.outcome
      when :updated
        redirect_to workspace_path(@workspace), notice: t("workspaces.update.updated")
      when :invalid
        @name_errors = result.errors.full_messages_for(:name)
        @metadata_errors = result.errors.full_messages_for(:metadata)
        refresh_workspace_and_render_edit(status: :unprocessable_entity)
      when :stale_object
        flash.now[:alert] = t("workspaces.changed_elsewhere")
        refresh_workspace_and_render_edit(status: :conflict, refresh_lock_version: true)
      when :workspace_not_active
        redirect_to workspace_path(@workspace), alert: t("workspaces.not_active")
      when :not_workspace_owner
        redirect_to workspace_path(@workspace), alert: t("workspaces.not_owner")
      when :not_found
        raise ActiveRecord::RecordNotFound
      else
        raise "unmapped workspace outcome: #{result.outcome.inspect}"
      end
    end

    # Invalid input keeps its attempted CAS so a concurrent winner is never
    # silently adopted; only a surfaced stale response advances it.
    def refresh_workspace_and_render_edit(status:, refresh_lock_version: false)
      @workspace.reload
      if refresh_lock_version
        @submitted_lock_version = @workspace.lock_version
      end
      render :edit, status: status
    end
end
