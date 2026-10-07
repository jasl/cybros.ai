require "test_helper"

# PRESENCE IS DISPLAY (r-modes M4): three words read off the executor row
# by the presenter, no clock, no window, no query — the live server set is
# loaded ONCE per page by the caller (`NexusServer.live_ids`) and passed
# down; a mark is online iff the `nexus_servers` row it names is live. And
# nothing in the correctness path may read it, pinned mechanically below.
class Nexus::PresenceTest < ActiveSupport::TestCase
  test "online while a pong-verified socket holds the row's mark under a live server" do
    executor = TaskExecutor.new(presence_connection_id: SecureRandom.uuid,
      presence_server_id: "boot-1", last_seen_at: Time.current)

    assert_equal "online", Nexus::Presence.of(executor, live_server_ids: [executor.presence_server_id])
  end

  test "offline once the mark is gone and a contact sample remains" do
    executor = TaskExecutor.new(presence_connection_id: nil, last_seen_at: 3.minutes.ago)

    assert_equal "offline", Nexus::Presence.of(executor, live_server_ids: ["boot-1"])
  end

  test "offline while the mark stands under a server that is not live" do
    executor = TaskExecutor.new(presence_connection_id: SecureRandom.uuid,
      presence_server_id: "boot-dead", last_seen_at: 3.minutes.ago)

    assert_equal "offline", Nexus::Presence.of(executor, live_server_ids: [])
    assert_equal "offline", Nexus::Presence.of(executor, live_server_ids: ["boot-other"])
  end

  test "not_yet_seen when the row has never contacted Nexus" do
    executor = TaskExecutor.new(presence_connection_id: nil, last_seen_at: nil)

    assert_equal "not_yet_seen", Nexus::Presence.of(executor, live_server_ids: [])
  end

  test "the three words are the whole vocabulary" do
    assert_equal %w[online offline not_yet_seen], Nexus::Presence::WORDS
  end

  # THE SIX FORBIDDEN READERS (Address, Claim, Commit, Inbox, Pool, InitialRunner) and every other
  # service or job: presence, the marks, the server liveness rows and the contact sample are never a
  # gate — "nothing in the correctness path depends on the cable, on presence, or on a heartbeat".
  # `\b` keeps `refresh_last_seen_at`, the one WRITER in services (rotate.rb), outside the net;
  # String#presence never matches. The one pruner is allowed by path: it is presence's own
  # housekeeping, not a reader of it.
  PRESENCE_HOUSEKEEPING = %w[app/jobs/nexus_servers/reap_job.rb].freeze

  test "no correctness path reads presence, the marks, the server rows or the contact sample" do
    pattern = /\blast_seen_at\b|\bpresence_connection_id\b|\bpresence_server_id\b|\bconnected_at\b|
      \bnexus_servers\b|\bNexusServer\b|Nexus::Presence/x
    files = Dir[Rails.root.join("app/services/**/*.rb"), Rails.root.join("app/jobs/**/*.rb")]
      .reject { |path| PRESENCE_HOUSEKEEPING.include?(path.delete_prefix("#{Rails.root}/")) }
    hits = files.flat_map do |path|
      File.readlines(path, encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
        "#{path.delete_prefix("#{Rails.root}/")}:#{index + 1}: #{line.strip}" if line.match?(pattern)
      end
    end

    assert_empty hits, "presence is display only; a service or job read it:\n#{hits.join("\n")}"
  end
end
