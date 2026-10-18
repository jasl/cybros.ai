module Nexus
  # PRESENCE FOR DISPLAY: the live, pong-verified executor socket, read off the
  # row's edge-written mark — `online` while an executor-inbox subscription holds
  # the row AND the Nexus process that wrote the mark is live (the database is
  # the authority: a mark names its writer's boot id, `NexusServer`), `offline`
  # once it does not and a contact sample exists, `not_yet_seen` when the row has
  # never contacted Nexus. The ONE home, presenter-computed and pure: no clock,
  # no window, no query — a presenter or helper loads `NexusServer.live_ids` ONCE
  # per page and passes it down; never per row. Never a delivery gate — nothing
  # in the correctness path reads it (pinned by test/lib/nexus/presence_test.rb).
  module Presence
    WORDS = %w[online offline not_yet_seen].freeze

    def self.of(executor, live_server_ids:)
      if executor.presence_connection_id.present? && live_server_ids.include?(executor.presence_server_id)
        "online"
      elsif executor.last_seen_at.present?
        "offline"
      else
        "not_yet_seen"
      end
    end
  end
end
