# The kernel tool catalog — the bytes a task must send to turn one on under
# its plain name, since `kernel_tool_redefined` refuses any declaration that
# is not byte-identical to the registry's. Splice an entry's `definition`
# straight into `tools`; `template` is the description's macro-bearing
# source, for an adaptation pack's recut. The render is the presenter's,
# shared with the contract pack's fixture.
# @auth [MemberBearer]
class AgentAPI::V1::ToolsController < AgentAPI::V1::BaseController
  serves_plane :member

  # @oas_include
  # @summary List tools
  # @tags Member, tools
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ToolsIndex
  def index
    render json: { tools: AgentAPI::ToolPresenter.index }
  end
end
