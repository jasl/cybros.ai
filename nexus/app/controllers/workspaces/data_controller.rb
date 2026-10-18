class Workspaces::DataController < Workspaces::BaseController
  before_action :load_data_workspace

  def show
  end

  private

    def load_data_workspace
      @workspace = workspace
      @data_writable = @workspace.data_writable_by?(Current.user)
    end

    def data_write_allowed?(template:, lifecycle_refusal: false)
      @data_writable = workspace.data_writable_by?(Current.user)
      return true if @data_writable

      if lifecycle_refusal && !workspace.live?
        render_data_refusal(:workspace_not_active, template: template)
      else
        render_data_refusal(:not_authorized, template: template, status: :forbidden)
      end
      false
    end

    def render_data_refusal(code, template:, status: nil, detail: nil)
      raise ActiveRecord::RecordNotFound if code == :not_found

      @error = t("data_console.errors.#{code}", detail: detail)
      @conflict = code == :stale_object
      status ||= Nexus::FamilyErrors.status_for(code)
      status ||= %i[workspace_not_active entry_limit_reached key_taken].include?(code) ? :conflict : :unprocessable_entity
      render template, status: status
    end
end
