# The rare owner-to-Human handover: the picker is owner-scoped to active
# same-Account Humans, no admin bypass; the domain independently rejects
# self-transfer, so a crafted request cannot render a false success.
class Workspaces::OwnershipTransfersController < Workspaces::BaseController
  PAGE_SIZE = 25
  SEARCH_QUERY_MAX_LENGTH = 100

  before_action :ensure_manageable

  def show
    @workspace = workspace
    @query = truncated_query(params.permit(:query)[:query])
    load_candidates
  end

  def create
    @workspace = workspace
    submitted = params.expect(ownership_transfer: [:target_user_public_id, :lock_version, :query])
    @query = truncated_query(submitted[:query])
    target = Current.account.users.members.find_by(
      public_id: submitted[:target_user_public_id].to_s
    )
    if target.nil?
      return render_picker(status: :unprocessable_entity, alert: t(".target_not_eligible"))
    end

    result = ::Workspaces::TransferOwnership.call(
      workspace: @workspace,
      by: Current.user,
      to: target,
      lock_version: submitted[:lock_version].to_i
    )

    case result.outcome
    when :transferred
      # A now-private workspace may already conceal itself from the loser, so
      # success lands on the index rather than the show page.
      redirect_to workspaces_path, notice: t(".transferred")
    when :target_not_eligible
      render_picker(status: :unprocessable_entity, alert: t(".target_not_eligible"))
    when :stale_object
      @workspace.reload
      render_picker(status: :conflict, alert: t("workspaces.changed_elsewhere"))
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

  private

    def truncated_query(value)
      value.to_s.strip[0, SEARCH_QUERY_MAX_LENGTH]
    end

    def render_picker(status:, alert:)
      load_candidates
      flash.now[:alert] = alert
      render :show, status: status
    end

    def load_candidates
      @candidates_pagy, @candidates = pagy(:offset, transfer_candidates, limit: PAGE_SIZE)
    end

    def transfer_candidates
      Current.account.active_humans_matching(@query).where.not(id: @workspace.owner_id)
    end
end
