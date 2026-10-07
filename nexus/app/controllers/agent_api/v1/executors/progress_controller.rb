# POST /agent_api/v1/executor/progress `{frame}` — the ephemeral frames an
# executor posts: what is only useful while it happens, broadcast on the
# host's `progress` feed and stored nowhere. The frame's KEY chooses the
# fence (the task's claim, or a process's originating claim); the cadence is taken BEFORE
# any row is read; a well-formed frame is `202` whether it was broadcast
# or dropped for cadence. The refusals: `409 not_claimant` (either claim proof), `422 frame_too_large` (the envelope bound) /
# `invalid_frame` (a key of neither kind, or a payload member of the wrong
# type), `404` for a host or a row this credential's account does not
# hold.
class AgentAPI::V1::Executors::ProgressController < AgentAPI::V1::Executors::BaseController
  # Thirty-two concurrent keys at the four-frame-per-second cadence consume
  # 7,680 requests/minute. Keep room for host progress beside task progress;
  # the per-key cadence below still drops redundant frames before row reads.
  self.caller_rate_limit = 10_000

  # THE CADENCE: ONE frame per key per `Executors::Progress::MIN_INTERVAL`
  # per kernel process, keyed by the frame's key bytes AND the poster's own
  # id (`Executors::Progress.key_of` — a stranger's flood cannot eat a
  # claimant's slot), taken here BEFORE the action reads a row, so a flood
  # costs the primary nothing after its first frame; a faster poster is
  # answered `202` and the frame dropped — never a refusal, never an exit
  # criterion (the drop is Rails' own `rate_limit.action_controller`
  # notification for an operator). A frame keyed by neither kind has no key
  # and no cadence: the door refuses it `422 invalid_frame` without a row
  # read. The store is the service's process-local one, not `Rails.cache`
  # (the reason is at the constant).
  rate_limit to: 1, within: Executors::Progress::MIN_INTERVAL, by: -> { frame_key },
    with: -> { head :accepted }, store: Executors::Progress::RATE, name: "frame-key", if: -> { frame_key }

  def create
    result = Executors::Progress.call(executor: current_executor, frame: frame)

    case result.outcome
    when :accepted
      head :accepted
    when :not_found
      render_error(:not_found, "Not found", status: :not_found)
    when :frame_too_large, :invalid_frame
      render_error(result.outcome.to_s, "Refused: #{result.outcome}", status: :unprocessable_entity)
    else
      render_error(result.outcome.to_s, "Refused: #{result.outcome}", status: :conflict)
    end
  end

  private

    # The frame is read off the parsed body verbatim — opaque payload
    # members (`structured`) must never pass through a permit.
    def frame = request.request_parameters["frame"]

    def frame_key
      return @frame_key if defined?(@frame_key)

      @frame_key = Executors::Progress.key_of(current_executor, frame)
    end
end
