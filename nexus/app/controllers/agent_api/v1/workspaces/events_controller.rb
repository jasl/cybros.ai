# The one replay window over a host — the OneShot events endpoint's twin:
# strictly-after exclusive cursor, ascending, hard-rejected limit, and the
# committed-max watermark a follower freezes to know its drain is done. A
# per-host subclass names the host; nothing else differs.
class AgentAPI::V1::Workspaces::EventsController < AgentAPI::V1::Workspaces::BaseController
  # Concurrent hosts retain HTTP recovery polling even with a live subscription.
  self.caller_rate_limit = 6000

  DEFAULT_LIMIT = 100
  MAX_LIMIT = 200

  def index
    host = self.host
    refusal = feed_refusal(host)
    return render_refusal(refusal) if refusal

    items = host.conversation_event_items
      .after_sequence(after_sequence)
      .order(:sequence)
      .limit(limit)
      .to_a

    render json: {
      events: items.map { |item| ConversationEventItem::PublicProjection.render(item) },
      pagination: {
        next_after: items.last &&
          ConversationEventItem::ReplayCursor.encode(items.last.sequence),
        watermark: host.event_watermark,
      },
    }
  end

  private

    # A host whose stream is another host's answers here; nil serves.
    def feed_refusal(_host) = nil

    def after_sequence = cursor_param(ConversationEventItem::ReplayCursor, :after)

    def limit = limit_param(default: DEFAULT_LIMIT, max: MAX_LIMIT)
end
