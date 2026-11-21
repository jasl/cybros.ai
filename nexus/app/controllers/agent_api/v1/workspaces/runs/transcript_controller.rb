# THE THREAD: the mainline's rounds newest-first behind an opaque cursor,
# returned in reading order, each with the calls it read and the branches
# under them; `prefix=<call>` answers the branch under that call in the
# same envelope. One density — the row is the row.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Runs::TranscriptController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  # @oas_include
  # @summary Read transcript
  # @tags Member, transcript
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRunsTranscriptShow
  # @response_ref (410) #/components/responses/APIError
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
