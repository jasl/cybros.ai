class Workspaces::MessagingController < Workspaces::BaseController
  before_action :ensure_manageable, only: :update

  def show
    load_page
    @agent_public_id = params.permit(:agent_public_id)[:agent_public_id].to_s
    settings = @agent_settings.find { |entry| entry.agent_public_id == @agent_public_id }
    @mode = settings&.mode || "public"
    @allowed_sender_public_ids = settings&.allowed_sender_public_ids || []
    @submitted_lock_version = @workspace.lock_version
  end

  def update
    submitted = params.expect(messaging: [:agent_public_id, :mode, :lock_version,
      allowed_sender_public_ids: []])
    @agent_public_id = submitted[:agent_public_id].to_s
    @mode = submitted[:mode].to_s
    @allowed_sender_public_ids = submitted.fetch(:allowed_sender_public_ids, []).map(&:to_s).reject(&:blank?)
    @submitted_lock_version = submitted_lock_version(submitted)
    load_page

    # The selector edits the receiving Agent within the complete policy,
    # including retained settings for an Agent that is no longer available.
    if !@agent_ids.include?(@agent_public_id)
      render_form(status: :unprocessable_entity, alert: t(".choose_agent"))
    elsif !%w[public private].include?(@mode)
      render_form(status: :unprocessable_entity, alert: t(".choose_mode"))
    else
      update_policy
    end
  end

  private

    # This form replaces the policy, so an omitted or malformed precondition
    # must never become an edit of the initial version zero.
    def submitted_lock_version(fields)
      version = Integer(fields.fetch(:lock_version).to_s, 10)
      raise ArgumentError unless (0..2_147_483_647).cover?(version)

      version
    rescue ArgumentError
      raise ActionController::BadRequest, "lock_version must be a nonnegative integer"
    end

    def load_page
      @workspace = workspace
      @agent_settings = @workspace.messaging_policy.agents
      agents = Current.account.users.members.where(kind: :agent)
        .includes(:steward, :derived_from).order_by_display_name.to_a
      available = agents.select { |agent| @workspace.data_accessible_by?(agent) }
      @available_ids = available.map(&:public_id)
      @agent_labels = agents.to_h do |agent|
        [agent.public_id, t("workspaces.messaging.show.agent_label", name: agent.display_name, handle: agent.handle)]
      end
      @agent_ids = (@available_ids + @agent_settings.map(&:agent_public_id)).uniq
      @sender_ids = (@available_ids + @agent_settings.flat_map(&:allowed_sender_public_ids)).uniq
      @editable = @workspace.active? && @workspace.manageable_by?(Current.user)
    end

    def update_policy
      agents = @agent_settings.reject { |entry| entry.agent_public_id == @agent_public_id }.map do |entry|
        { agent_public_id: entry.agent_public_id, mode: entry.mode, allowed_sender_public_ids: entry.allowed_sender_public_ids }
      end
      agents << { agent_public_id: @agent_public_id, mode: @mode, allowed_sender_public_ids: @allowed_sender_public_ids }
      result = ::Workspaces::UpdateMessaging.call(
        workspace: @workspace, by: Current.user, agents: agents,
        lock_version: @submitted_lock_version
      )

      case result.outcome
      when :updated
        redirect_to workspace_messaging_path(@workspace, agent_public_id: @agent_public_id),
          status: :see_other, notice: t(".updated")
      when :invalid
        @errors = result.errors.full_messages_for(:messaging_policy)
        workspace.reload
        render_form(status: :unprocessable_entity, alert: t(".invalid"))
      when :stale_object
        workspace.reload
        @submitted_lock_version = workspace.lock_version
        render_form(status: :conflict, alert: t("workspaces.changed_elsewhere"))
      when :workspace_not_active
        redirect_to workspace_path(workspace), alert: t("workspaces.not_active")
      when :not_workspace_owner
        redirect_to workspace_path(workspace), alert: t("workspaces.not_owner")
      when :not_found
        raise ActiveRecord::RecordNotFound
      else
        raise "unmapped workspace outcome: #{result.outcome.inspect}"
      end
    end

    def render_form(status:, alert:)
      load_page
      flash.now[:alert] = alert
      render :show, status: status
    end
end
