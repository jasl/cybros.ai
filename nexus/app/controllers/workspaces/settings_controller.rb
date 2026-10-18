class Workspaces::SettingsController < Workspaces::BaseController
  def show
    @workspace = workspace
  end
end
