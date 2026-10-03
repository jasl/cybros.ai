# The loop's door: the one inputs body over the listable LOOP row — never its
# host, so a loop-backed loop is refused under its own lock rather than silently
# forwarded. The refusal names the door it should have knocked on.
class AgentAPI::V1::Workspaces::AgentLoops::InputsController <
      AgentAPI::V1::Workspaces::InputsController
  include AgentAPI::V1::WorkspaceScoped

  private

    def host
      @host ||= find_listable_loop(@workspace)
    end

    def render_refusal(refusal)
      return super unless refusal == :conversation_hosted

      turn = host.conversation_turn
      render_extended_error(:conversation_hosted, "Refused: conversation_hosted", status: :conflict,
        conversation_public_id: turn.conversation.public_id, turn_public_id: turn.public_id)
    end
end
