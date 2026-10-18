# Tail edit: the caller's content becomes a new activated candidate.
class AgentAPI::V1::Workspaces::Conversations::Turns::EditsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

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
