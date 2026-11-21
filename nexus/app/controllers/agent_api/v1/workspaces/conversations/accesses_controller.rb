# THE ACCESS CARRIER'S LATER CHANGE: a nested singular resource, PUT and
# never the PATCH twin — a whole replacement of the default and the
# entries, the handoff's shape. Through the one funnel, so a `none`
# principal finds the door absent before any standing is judged; the
# standing itself is the row's `writable_by?` (full on the row with
# workspace write standing). 200 answers the conversation document; the
# same set is a plain 200 with no fact written.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::AccessesController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Update accesses
  # @tags Member, accesses
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesConversationsAccessesUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsAccessesUpdate
  def update
    conversation = find_listable_conversation(@workspace)
    fields = params.expect(access: [:default, { entries: [[:user_public_id, :handle, :level]] }])

    result = ::Conversations::SetAccess.call(::Conversations::SetAccess::Command.new(
      conversation: conversation, acting_user: acting_user,
      default: fields[:default].to_s, entries: Array(fields[:entries]).map(&:to_h)
    ))

    if result.accepted?
      render json: { conversation: AgentAPI::ConversationPresenter.full(result.value, acting_user: acting_user) }
    elsif result.invalid?
      render_domain_invalid(result.record.errors)
    else
      render_refusal(result.outcome)
    end
  end
end
