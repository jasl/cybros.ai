# Tail edit: the caller's content becomes a new activated candidate.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::Turns::EditsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Create edits
  # @tags Member, edits
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter turn_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesConversationsTurnsEditsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsTurnsEditsCreate
  def create
    conversation = find_listable_conversation(@workspace)
    fields = params.permit(edit: [:text]).fetch(:edit)

    result = ::Conversations::Turns::Edit.call(::Conversations::Turns::Edit::Command.new(
      conversation: conversation,
      turn_public_id: params.fetch(:turn_public_id),
      entries: edit_entries(fields),
      acting_user: acting_user,
    ))

    if result.accepted?
      variant = result.value
      # The sibling carries the origin's `prompt` body when the origin had
      # one (Edit#carry_prompt): a reply turn's seed rides the answer.
      render json: {
        variant: AgentAPI::ConversationPresenter.variant(
          variant, body: variant.content_bodies.find_by(role: "content"), active: true,
          prompt: variant.content_bodies.find_by(role: "prompt")
        ),
      }
    else
      render_refusal(result.outcome)
    end
  end

  private

    def edit_entries(fields)
      raw = Array.try_convert(request.request_parameters.dig("edit", "entries"))
      if raw
        unless raw.all? { |element| Hash.try_convert(element) }
          raise APIErrors::ParameterInvalid, :entries
        end

        return raw
      end

      fields[:text].present? ? [{ "text" => fields[:text] }] : nil
    end
end
