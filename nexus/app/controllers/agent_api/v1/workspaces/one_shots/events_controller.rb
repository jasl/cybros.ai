# The durable replay window: strictly-after cursor, ascending, exclusive — the
# recovery path the realtime stream leans on. The limit is a hard reject, not
# a clamp.
class AgentAPI::V1::Workspaces::OneShots::EventsController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # Replay polling scales with the number of concurrent OneShots.
  self.caller_rate_limit = 6000

  DEFAULT_LIMIT = 100
  MAX_LIMIT = 200

  def index
    one_shot = OneShot.where(workspace_id: @workspace.id).listable
      .find_by!(public_id: params.fetch(:one_shot_public_id))

    items = one_shot.one_shot_event_items
      .after_sequence(after_sequence)
      .order(:sequence)
      .limit(limit)
      .to_a

    render json: {
      events: items.map { |item| OneShotEventItem::PublicProjection.render(item) },
      pagination: {
        next_after: items.last && OneShotEventItem::ReplayCursor.encode(items.last.sequence),
        watermark: watermark_for(one_shot),
      },
    }
  end

  private

    # The head of the stream as of this request — what a follower freezes to
    # know its drain is complete. OneShot retains its items with the host,
    # so their committed MAX remains the head; a sequence, not a cursor.
    def watermark_for(one_shot)
      one_shot.one_shot_event_items.maximum(:sequence).to_i
    end

    def after_sequence = cursor_param(OneShotEventItem::ReplayCursor, :after)

    def limit = limit_param(default: DEFAULT_LIMIT, max: MAX_LIMIT)
end
