# THE THREAD: the spine's rounds newest-first behind an opaque cursor,
# returned in reading order, each with the calls it read and the branches
# under them; `prefix=<call>` answers the branch under that call in the
# same envelope. One density — the row is the row.
class AgentAPI::V1::Workspaces::AgentLoops::TranscriptController <
      AgentAPI::V1::Workspaces::AgentLoops::BaseController
  def show
    agent_loop = find_listable_loop(@workspace)
    prefix = params[:prefix].presence
    result = AgentLoops::Transcript.call(
      agent_loop: agent_loop, before: cursor_param(AgentLoopNode::TranscriptCursor, :before),
      limit: limit_param(default: AgentLoops::Transcript::DEFAULT_LIMIT, max: AgentLoops::Transcript::MAX_LIMIT),
      prefix: prefix
    )
    # The presenter's one miss: a prefix that names no call of this loop —
    # one code for one miss, the family's (`render_adjudication_refusal`).
    return render_adjudication_refusal(:not_found) if result.refused?

    render json: {
      rounds: result.rounds,
      pagination: { next_before: result.next_before, has_older: result.has_older },
    }
  end
end
