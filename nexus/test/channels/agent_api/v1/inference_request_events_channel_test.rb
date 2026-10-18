require "test_helper"

# The realtime mirror's authorization mirrors REST tier by tier, and every
# rejection happens before any resource detail could leak.
class AgentAPI::V1::InferenceRequestEventsChannelTest < ActionCable::Channel::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @inference_request = InferenceRequest.create!(
      account: @account, workspace: @workspace, creating_user: @human,
      workload: "text_generation"
    )
    @token = create_access_token_fixture(user: @human, name: "M").token
  end

  # ONE OWNER of the name (review rank 14): the two channels subscribe by
  # it and the broadcast and transcript seams publish by it, so the bytes
  # cannot drift apart across the four sites.
  test "the stream name has one owner, and this channel is the host's subclass" do
    assert_equal "agent_api:v1:inference_request:os-1:events",
      AgentAPI::V1::EventsChannel.stream_name("inference_request", "os-1", "events")
    assert_operator AgentAPI::V1::InferenceRequestEventsChannel, :<, AgentAPI::V1::EventsChannel
    assert_nil AgentAPI::V1::InferenceRequestEventsChannel::FEEDS["transcript"], "a InferenceRequest has no turns to transcribe"
    assert_nil AgentAPI::V1::InferenceRequestEventsChannel::FEEDS["progress"], "nothing an executor posts names a InferenceRequest"
    assert_equal "progress", AgentAPI::V1::EventsChannel::FEEDS["progress"], "the hosted plane's feed word"
  end

  test "a member credential with access subscribes to the one stream" do
    stub_connection(current_user: @human, current_access_token: @token)

    subscribe workspace_id: @workspace.public_id, inference_request_id: @inference_request.public_id

    assert subscription.confirmed?
    assert_has_stream "agent_api:v1:inference_request:#{@inference_request.public_id}:events"
  end

  # NOT EVERY CONSUMER IS READING THE OUTPUT. A client watching one
  # conversation out of several still wants to know when the others finish, and
  # making it subscribe to the full stream would hand it every delta to decode
  # and discard. The narrowing is a different broadcasting, so an uninterested
  # subscriber receives nothing rather than filtering.
  test "a lifecycle subscriber streams from the narrowed broadcasting" do
    stub_connection(current_user: @human, current_access_token: @token)

    subscribe workspace_id: @workspace.public_id, inference_request_id: @inference_request.public_id,
              items: "lifecycle"

    assert subscription.confirmed?
    assert_has_stream "agent_api:v1:inference_request:#{@inference_request.public_id}:lifecycle"
    assert_has_no_stream "agent_api:v1:inference_request:#{@inference_request.public_id}:events"
  end

  test "an unknown items value rejects instead of silently widening" do
    stub_connection(current_user: @human, current_access_token: @token)

    subscribe workspace_id: @workspace.public_id, inference_request_id: @inference_request.public_id,
              items: "nonesuch"

    assert subscription.rejected?
  end

  test "a token revoked after connection cannot start a new subscription" do
    stub_connection(current_user: @human, current_access_token: @token)
    AccessTokens::Revoke.call(AccessToken.find(@token.id))
    assert_nil @token.revoked_at, "the connection deliberately still holds its pre-revoke record"

    subscribe workspace_id: @workspace.public_id, inference_request_id: @inference_request.public_id

    assert subscription.rejected?
  end

  test "a cookie connection carries no member credential and is rejected" do
    stub_connection(current_user: @human, current_access_token: nil)

    subscribe workspace_id: @workspace.public_id, inference_request_id: @inference_request.public_id

    assert subscription.rejected?
  end

  test "no access, a tombstoned workspace, and a tombstoned InferenceRequest all reject" do
    foreign = create_access_token_fixture(user: users(:curator), name: "F").token
    stub_connection(current_user: users(:curator), current_access_token: foreign)
    subscribe workspace_id: workspaces(:personal).public_id, inference_request_id: @inference_request.public_id
    assert subscription.rejected?, "a reachable workspace with a foreign InferenceRequest rejects"

    stub_connection(current_user: @human, current_access_token: @token)
    @inference_request.update_columns(tombstoned_at: Time.current)
    subscribe workspace_id: @workspace.public_id, inference_request_id: @inference_request.public_id
    assert subscription.rejected?

    @inference_request.update_columns(tombstoned_at: nil)
    @workspace.update_columns(state: "deleted", deleted_at: Time.current)
    stub_connection(current_user: @human, current_access_token: @token)
    subscribe workspace_id: @workspace.public_id, inference_request_id: @inference_request.public_id
    assert subscription.rejected?
  end

  test "a real lifecycle append reaches both streams in the replay projection" do
    stub_connection(current_user: @human, current_access_token: @token)
    subscribe workspace_id: @workspace.public_id, inference_request_id: @inference_request.public_id

    lifecycle_messages = nil
    messages = capture_broadcasts("agent_api:v1:inference_request:#{@inference_request.public_id}:events") do
      lifecycle_messages = capture_broadcasts(
        "agent_api:v1:inference_request:#{@inference_request.public_id}:lifecycle"
      ) do
        InferenceRequestEvents::Append.call(
          inference_request: @inference_request,
          items: [{ type: "run_status", payload: { "status" => "failed" } }]
        )
      end
    end

    event = messages.sole.fetch("event")
    assert_equal event, lifecycle_messages.sole.fetch("event")
    assert_equal "run_status", event.fetch("type")
    assert_equal @inference_request.public_id, event.dig("resource", "public_id")
    assert event.key?("cursor"), "the cable carries the replay projection, cursor included"
  end

  test "workspace authority withdrawal unsubscribes before later frames" do
    stub_connection(current_user: @human, current_access_token: @token)
    subscribe workspace_id: @workspace.public_id, inference_request_id: @inference_request.public_id

    remote_connections = Object.new
    channel_subscription = subscription
    disconnected_user = @human
    disconnected_token = @token
    remote_connections.define_singleton_method(:where) do |current_user:, current_access_token:, current_executor_token:|
      raise "an executor identity on a member cut" unless current_executor_token.nil?

      remote_connection = Object.new
      remote_connection.define_singleton_method(:disconnect) do |reconnect:|
        raise "workspace subscribers must be allowed to reconnect" unless reconnect

        if current_user == disconnected_user && current_access_token == disconnected_token
          channel_subscription.unsubscribe_from_channel
        end
      end
      remote_connection
    end

    ActionCable.server.stub(:remote_connections, remote_connections) do
      result = Workspaces::UpdateAccessMode.call(
        workspace: @workspace, by: users(:owner), to: :private,
        lock_version: @workspace.lock_version
      )
      assert_equal :updated, result.outcome
    end

    assert_no_streams
    delivered = transmissions.length
    InferenceRequestEvents::Append.call(
      inference_request: @inference_request,
      items: [{ type: "text_delta", payload: { "delta" => "too late" } }]
    )
    assert_equal delivered, transmissions.length
  end

  test "a rolled-back append broadcasts nothing" do
    messages = capture_broadcasts("agent_api:v1:inference_request:#{@inference_request.public_id}:events") do
      ApplicationRecord.transaction do
        InferenceRequestEvents::Append.call(
          inference_request: @inference_request,
          items: [{ type: "run_status", payload: { "status" => "failed" } }]
        )
        raise ActiveRecord::Rollback
      end
    end

    assert_empty messages, "the publish rides the commit, and there was none"
  end
end
