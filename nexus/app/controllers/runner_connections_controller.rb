class RunnerConnectionsController < ApplicationController
  def show
    @agents_pagy, @agents = pagy(:offset,
      Current.user.stewarded_agents.active.where(named_agent_scope: nil).order_by_display_name, limit: 10)
  end
end
