# The one replay window over a host — the InferenceRequest events endpoint's twin:
# strictly-after exclusive cursor, ascending, hard-rejected limit, and the
# committed-max watermark a follower freezes to know its drain is done. A
# per-host subclass names the host; nothing else differs.
class AgentAPI::V1::Workspaces::EventsController < AgentAPI::V1::Workspaces::BaseController
  # Concurrent hosts retain HTTP recovery polling even with a live subscription.
  self.caller_rate_limit = 6000

  DEFAULT_LIMIT = 100
  MAX_LIMIT = 200

  # @oas_include
  # @summary List events
  # @tags Member, events
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesEventsIndex
  def index
    host = self.host
    refusal = feed_refusal(host)
    return render_refusal(refusal) if refusal

    items = host.event_items
      .after_sequence(after_sequence)
      .order(:sequence)
      .limit(limit)
      .to_a

    render json: {
      events: items.map { |item| EventItem::PublicProjection.render(item) },
      pagination: {
        next_after: items.last &&
          EventItem::ReplayCursor.encode(items.last.sequence),
        watermark: host.event_watermark,
      },
    }
  end

  private

    # A host whose stream is another host's answers here; nil serves.
    def feed_refusal(_host) = nil

    def after_sequence = cursor_param(EventItem::ReplayCursor, :after)

    def limit = limit_param(default: DEFAULT_LIMIT, max: MAX_LIMIT)
end
