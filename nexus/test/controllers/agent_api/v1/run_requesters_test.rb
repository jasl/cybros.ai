require "test_helper"
require "test_helpers/run_api_test_helper"

class AgentAPI::V1::RunRequestersTest < ActionDispatch::IntegrationTest
  include RunAPITestHelper
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @agent = users(:agent)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: @agent.agent_identifier)
    @token = BoundCredential.new(token: connection.access_token, secret: connection.access_secret)
    @speaker = Speaker.register_ingress(user: @agent, channel_key: "bridge", external_id: "requester", display_name: "Ada")
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent, tools: [Nexus::Tools::SPAWN])
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @agent, answering_user: @agent)
  end

  test "Run detail names its ingress requester without adding it to the listing" do
    run = start_request

    assert_equal @speaker.public_id, read_run(run).fetch("requester_speaker_public_id")
    get loops_path, headers: auth
    assert_response :success
    assert_not response.parsed_body.fetch("runs").sole.key?("requester_speaker_public_id")
  end

  test "a spawned child's detail follows the accepted source instead of the spawner's voice" do
    parent = start_request
    schedule_loop!(parent)
    run_loop_round!(parent, sse_success("Delegating.", tool_calls: [
      { id: "worker", name: "spawn", arguments: { prompt: "Review the result." }.to_json },
    ]))
    call = parent.tasks.find_by!(tool_name: "spawn")
    Runs::ConversationToolJob.perform_now(call.id)
    child = call.reload.spawned_conversation
    applied = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert_predicate applied, :accepted?, applied.outcome.to_s
    turn = applied.value
    assert_equal @agent, turn.speaker.user
    assert_equal @speaker.public_id, read_run(turn.active_variant.run).fetch("requester_speaker_public_id")
  end

  test "a standalone Run has no originating conversation requester" do
    run = loop_record(create_loop!)

    assert_nil read_run(run).fetch("requester_speaker_public_id")
  end

  private

    def start_request
      post "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{@conversation.public_id}/inputs",
        headers: auth(SecureRandom.uuid_v7), as: :json, params: {
          input: { kind: "direct_reply", text: "Please review this.", model: MODEL, speaker_public_id: @speaker.public_id },
        }
      assert_response :accepted
      applied = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
      assert_predicate applied, :accepted?, applied.outcome.to_s
      applied.value.active_variant.run
    end

    def read_run(run)
      get "#{loops_path}/#{run.public_id}", headers: auth
      assert_response :success
      response.parsed_body.fetch("run")
    end
end
