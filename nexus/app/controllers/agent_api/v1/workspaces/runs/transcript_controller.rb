# THE THREAD: the mainline's rounds newest-first behind an opaque cursor,
# returned in reading order, each with the calls it read and the branches
# under them; `prefix=<call>` answers the branch under that call in the
# same envelope. One density — the row is the row.
class AgentAPI::V1::Workspaces::Runs::TranscriptController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  def show
    run = find_listable_loop(@workspace)
    prefix = params[:prefix].presence
    result = Runs::Transcript.call(
      run: run, before: cursor_param(Task::TranscriptCursor, :before),
      limit: limit_param(default: Runs::Transcript::DEFAULT_LIMIT, max: Runs::Transcript::MAX_LIMIT),
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
