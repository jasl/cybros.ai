# The kernel tool catalog — the bytes a task must send to turn one on under
# its plain name, since `kernel_tool_redefined` refuses any declaration that
# is not byte-identical to the registry's. Splice an entry's `definition`
# straight into `tools`; `template` is the description's macro-bearing
# source, for an adaptation pack's recut. The render is the presenter's,
# shared with the contract pack's fixture.
class AgentAPI::V1::ToolsController < AgentAPI::V1::BaseController
  serves_plane :member

  def index
    render json: { tools: AgentAPI::ToolPresenter.index }
  end
end
