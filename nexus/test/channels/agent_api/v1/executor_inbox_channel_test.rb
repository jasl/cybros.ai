require "test_helper"

# ONE channel keyed by executor: the credential names the address, so the subscription reads no
# params; a member bearer holds no executor identity and is rejected. The stream name carries no
# epoch — the subscription dies with the credential (the connection's recheck).
#
# PRESENCE RIDES ITS EDGES (r-modes M4): `subscribed` marks the row with this
# connection's id, `unsubscribed` clears the mark iff it is still this
# connection's, and `pong` keeps the socket honest. Nothing here is a gate.
class AgentAPI::V1::ExecutorInboxChannelTest < ActionCable::Channel::TestCase
  setup do
    @executor = task_executors(:address)
    @transport = create_bound_credential(executor: @executor, name: "Transport").token
  end

  test "a transport bearer subscribes its own executor's stream, reading no params" do
    stub_connection(current_executor_token: @transport)
    subscribe({ workspace_id: "ignored", executor_id: "ignored-too" })

    assert subscription.confirmed?
    assert_has_stream "agent_api:v1:executor:#{@executor.public_id}:inbox"
    assert_equal ["agent_api:v1:executor:#{@executor.public_id}:inbox"], subscription.send(:streams).keys,
      "the one stream, and no param reached its name"
  end

  test "a member bearer is rejected: it holds no executor identity" do
    member = create_access_token_fixture(user: users(:member), name: "Member").token
    stub_connection(current_user: users(:member), current_access_token: member)
    subscribe

    assert subscription.rejected?
    assert_nil @executor.reload.presence_connection_id, "a rejected subscription marks nothing"
  end

  test "a re-paired executor's old credential is rejected at subscribe" do
    @executor.re_pair(display_name: "again")
    stub_connection(current_executor_token: @transport)
    subscribe

    assert subscription.rejected?
  end

  test "subscribing marks the row with this connection's id, and unsubscribing clears it" do
    stub_connection(current_executor_token: @transport)
    subscribe

    assert subscription.confirmed?
    @executor.reload
    assert_equal connection.presence_id, @executor.presence_connection_id
    assert_equal NexusServer.boot_id, @executor.presence_server_id, "the mark names the process that wrote it"
    assert_not_nil @executor.connected_at
    assert_equal "online", Nexus::Presence.of(@executor, live_server_ids: [NexusServer.boot_id])
    assert connection.pongs_expected?, "the pong expectation is armed by the subscription, never before"

    @executor.update!(last_seen_at: Time.current)
    unsubscribe

    @executor.reload
    assert_nil @executor.presence_connection_id
    assert_nil @executor.presence_server_id
    assert_nil @executor.connected_at
    assert_equal "offline", Nexus::Presence.of(@executor, live_server_ids: [NexusServer.boot_id])
  end

  # THE RECONNECT OVERLAP: a newer connection's mark is a whole replacement, and the older
  # connection's close clears only its own.
  test "an older connection's unsubscribe never erases a newer connection's mark" do
    stub_connection(current_executor_token: @transport)
    older = subscribe
    older_connection = connection

    stub_connection(current_executor_token: @transport)
    subscribe
    newer_id = connection.presence_id
    assert_not_equal older_connection.presence_id, newer_id
    assert_equal newer_id, @executor.reload.presence_connection_id, "the newer connection replaced the mark whole"

    older.unsubscribe_from_channel

    assert_equal newer_id, @executor.reload.presence_connection_id
    assert_equal "online", Nexus::Presence.of(@executor, live_server_ids: [NexusServer.boot_id])
  end

  test "the pong action answers the connection's expectation" do
    stub_connection(current_executor_token: @transport)
    subscribe
    ponged = 0
    connection.define_singleton_method(:pong) { ponged += 1 }

    perform :pong

    assert_equal 1, ponged
  end

  # The guard is the id, not the epoch: a subscription whose credential was
  # fenced while it was open still clears the mark it made (re_pair itself
  # clears too — this pins the channel's own edge).
  test "a re-paired credential's unsubscribe still clears the mark it made" do
    stub_connection(current_executor_token: @transport)
    subscribe
    marked = connection.presence_id
    @executor.reload.update_columns(credential_epoch: @executor.credential_epoch + 1, presence_connection_id: marked)
    assert_nil connection.verified_executor_token, "the credential is fenced by the epoch"

    unsubscribe

    assert_nil @executor.reload.presence_connection_id
  end
end
