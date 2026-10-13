# THE THREAD: the mainline's rounds newest-first behind an opaque cursor,
# returned in reading order, each with the calls it read and the branches
# under them; `prefix=<call>` answers the branch under that call in the
# same envelope. One density — the row is the row.
class AgentAPI::V1::Workspaces::AgentRuns::TranscriptController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  def show
    agent_run = find_listable_loop(@workspace)
    prefix = params[:prefix].presence
    result = AgentRuns::Transcript.call(
      agent_run: agent_run, before: cursor_param(AgentRunTask::TranscriptCursor, :before),
      limit: limit_param(default: AgentRuns::Transcript::DEFAULT_LIMIT, max: AgentRuns::Transcript::MAX_LIMIT),
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
