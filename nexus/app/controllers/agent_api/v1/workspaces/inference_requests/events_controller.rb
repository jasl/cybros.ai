# The durable replay window: strictly-after cursor, ascending, exclusive — the
# recovery path the realtime stream leans on. The limit is a hard reject, not
# a clamp.
class AgentAPI::V1::Workspaces::InferenceRequests::EventsController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # Replay polling scales with the number of concurrent InferenceRequests.
  self.caller_rate_limit = 6000

  DEFAULT_LIMIT = 100
  MAX_LIMIT = 200

  def index
    inference_request = InferenceRequest.where(workspace_id: @workspace.id).listable
      .find_by!(public_id: params.fetch(:inference_request_public_id))

    items = inference_request.inference_request_event_items
      .after_sequence(after_sequence)
      .order(:sequence)
      .limit(limit)
      .to_a

    render json: {
      events: items.map { |item| InferenceRequestEventItem::PublicProjection.render(item) },
      pagination: {
        next_after: items.last && InferenceRequestEventItem::ReplayCursor.encode(items.last.sequence),
        watermark: watermark_for(inference_request),
      },
    }
  end

  private

    # The head of the stream as of this request — what a follower freezes to
    # know its drain is complete. InferenceRequest retains its items with the host,
    # so their committed MAX remains the head; a sequence, not a cursor.
    def watermark_for(inference_request)
      inference_request.inference_request_event_items.maximum(:sequence).to_i
    end

    def after_sequence = cursor_param(InferenceRequestEventItem::ReplayCursor, :after)

    def limit = limit_param(default: DEFAULT_LIMIT, max: MAX_LIMIT)
end
