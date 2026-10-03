# The member console's one rendering of Nexus::Presence: the word beside the
# executor, the contact sample as the tooltip. A missing address reads as
# never seen. The live server set is loaded ONCE per request and shared by
# every row on the page (the runners index).
module PresenceHelper
  def presence_label(executor)
    return "Not yet seen" if executor.nil?

    case Nexus::Presence.of(executor, live_server_ids: live_server_ids)
    when "online" then "Online"
    when "offline" then "Offline · last seen #{time_ago_in_words(executor.last_seen_at)} ago"
    else "Not yet seen"
    end
  end

  private

    def live_server_ids = @live_server_ids ||= NexusServer.live_ids
end
