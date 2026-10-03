require "test_helper"

# The loop host's realtime mirror, the conversation channel's twin over one base: token, feed,
# workspace, listable loop — and a loop-backed loop rejects like absence, because its stream is its
# conversation's.
class AgentAPI::V1::AgentLoopEventsChannelTest < ActionCable::Channel::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @agent_loop = AgentLoop.create!(workspace: @workspace, creating_user: @human, approval_mode: "bypass")
    @token = create_access_token_fixture(user: @human, name: "Member").token
  end

  def subscribe_with(items: nil, agent_loop: @agent_loop, workspace: @workspace)
    stub_connection(current_user: @human, current_access_token: @token)
    payload = { workspace_id: workspace.public_id, agent_loop_id: agent_loop.public_id }
    payload[:items] = items if items
    subscribe(payload)
  end

  test "the default feed is the full stream; lifecycle and transcript narrow" do
    subscribe_with
    assert subscription.confirmed?
    assert_has_stream "agent_api:v1:agent_loop:#{@agent_loop.public_id}:events"

    unsubscribe
    subscribe_with(items: "lifecycle")
    assert_has_stream "agent_api:v1:agent_loop:#{@agent_loop.public_id}:lifecycle"

    unsubscribe
    subscribe_with(items: "transcript")
    assert_has_stream "agent_api:v1:agent_loop:#{@agent_loop.public_id}:transcript"

    # THE EPHEMERAL FEED: the frames an executor posts under the loop's own binding, on their own
    # broadcasting.
    unsubscribe
    subscribe_with(items: "progress")
    assert_has_stream "agent_api:v1:agent_loop:#{@agent_loop.public_id}:progress"
  end

  test "an unknown feed and a tombstoned loop both reject like absence" do
    subscribe_with(items: "everything")
    assert subscription.rejected?

    @agent_loop.update!(status: "completed", tombstoned_at: Time.current)
    subscribe_with
    assert subscription.rejected?
  end

  # An executor socket carries no member standing: the member feeds see no verified member token and
  # reject like absence.
  test "an executor socket cannot subscribe a member feed" do
    transport = create_bound_credential(executor: task_executors(:address), name: "Transport").token
    stub_connection(current_executor_token: transport)
    subscribe({ workspace_id: @workspace.public_id, agent_loop_id: @agent_loop.public_id })

    assert subscription.rejected?
  end

  test "a loop-backed loop rejects: its stream is its conversation's" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_loop_backed_turn(conversation: conversation, acting_user: @human)

    subscribe_with(agent_loop: seam.agent_loop)

    assert subscription.rejected?
  end
end
