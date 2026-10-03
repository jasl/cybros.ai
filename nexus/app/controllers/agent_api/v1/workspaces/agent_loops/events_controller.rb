# The loop's feed: the one events body over the listable loop. A loop-backed
# loop's stream is its conversation's, so it refuses by name.
class AgentAPI::V1::Workspaces::AgentLoops::EventsController <
      AgentAPI::V1::Workspaces::EventsController
  include AgentAPI::V1::WorkspaceScoped

  private

    def host = find_listable_loop(@workspace)

    def feed_refusal(host) = (:conversation_hosted unless host.standalone?)
end
