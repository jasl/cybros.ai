# @auth [MemberBearer]
class AgentAPI::V1::AttentionController < AgentAPI::V1::Workspaces::BaseController
  include AttentionListing

  # @oas_include
  # @summary Read attention
  # @tags Member, attention
  # @response_ref (200) #/components/responses/AgentApiV1AttentionShow
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  def show
    page = attention_page
    live_server_ids = NexusServer.live_ids
    render json: {
      items: page.records.map { |task|
        run = task.run
        {
          workspace_public_id: run.workspace.public_id,
          run_public_id: run.public_id,
          conversation_public_id: (run.turn.conversation.public_id unless run.standalone?),
          task: AgentAPI::RunPresenter.task(task, live_server_ids: live_server_ids),
        }
      },
      pagination: { next_after: page.next_after },
    }
  end
end
