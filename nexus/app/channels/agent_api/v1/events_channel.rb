# The realtime mirror of a host's replay stream: the durable rows are the
# truth, the replay endpoint is the recovery path, this carries the same
# projected items with lower latency. Authorization mirrors REST tier by
# tier; access loss, tombstones and a host whose stream is another's all
# reject like absence, before any resource detail leaks. A per-host
# subclass finds the host and may narrow FEEDS; nothing else differs.
class AgentAPI::V1::EventsChannel < ApplicationCable::Channel
  FEEDS = {
    "events" => "events",
    "lifecycle" => "lifecycle",
    # The human-facing feed: deltas while a round runs, and the settled
    # snapshot when a turn or task terminalizes. A console takes
    # `lifecycle`, a debugger `events`, a chat surface `transcript` —
    # nobody decodes what they will discard.
    "transcript" => "transcript",
    # THE EPHEMERAL FEED: frames an executor posts while its work happens
    # — a `bash` tail under a claim, a process's output under the host's
    # binding — under the envelope `{frame}`, never `{event}`. Nothing on
    # it is durable and nothing replays: a subscriber sees what follows. A
    # InferenceRequest narrows it away with `transcript`.
    "progress" => "progress",
  }.freeze

  def self.stream_name(...) = Nexus::RealtimeStreams.resource(...)

  def subscribed
    token = connection.verified_member_access_token
    return reject if token.nil?

    feed = feed_name
    return reject if feed.nil?

    workspace = Workspace.data_accessible_to(token.user).browsable
      .find_by(public_id: params[:workspace_id])
    return reject if workspace.nil?

    host = find_host(workspace, token.user)
    return reject if host.nil?

    stream_from self.class.stream_name(Nexus::RealtimeStreams.resource_type(host), host.public_id, feed)
  end

  private

    # `find_host(workspace, user)` is each subclass's: the host row through
    # the same funnel its REST doors read, or nil, which rejects like absence.
    # `events` carries every projected item; `lifecycle` only where the host
    # IS and when it needs a human — for a consumer holding many and reading
    # none, filtered at the broadcasting rather than here. `transcript`
    # carries what a turn SAID, and is published by its own seam. Read off
    # the subclass, so a host that narrows FEEDS narrows what it admits.
    def feed_name
      self.class::FEEDS[params.fetch(:items, "events").to_s]
    end
end
