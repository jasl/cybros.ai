# The conversation resources' plumbing: the listable funnel and the one
# refusal map live on the workspace base (a loop-hosted door inherits them
# too); what stays here is the reply lane's own assembly-intent readers.
class AgentAPI::V1::Workspaces::Conversations::BaseController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::AssemblyIntents

  private

    # The recycle bin's two verbs share one shape: find, authorize, run,
    # answer with the row's fresh state. Lifecycle verbs are WRITES with
    # destructive reach — a browsable-but-not-writable caller reads; the
    # finder runs first so a concealed row is absence, never a refusal.
    def lifecycle_command(command)
      conversation = find_listable_conversation(@workspace)
      return unless authorize_writable(conversation)

      result = command.call(conversation: conversation)
      if result.accepted?
        render json: {
          conversation: AgentAPI::ConversationPresenter.full(result.value.reload, acting_user: acting_user),
        }
      else
        render_refusal(result.outcome)
      end
    end
end
