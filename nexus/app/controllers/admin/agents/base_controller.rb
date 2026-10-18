class Admin::Agents::BaseController < Admin::BaseController
  before_action :set_agent

  private

    def set_agent
      @member = Current.account.users.members.where(kind: :agent).find_by!(public_id: params[:agent_id])
    end
end
