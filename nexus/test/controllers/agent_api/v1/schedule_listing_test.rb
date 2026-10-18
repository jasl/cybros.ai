require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"
require_relative "../../../test_helpers/schedules_console_test_helper"

class AgentAPI::V1::ScheduleListingTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper
  include SchedulesConsoleTestHelper

  setup { @conversation = schedule_conversation }

  test "global, workspace and conversation lists filter status before their bounded page" do
    active = console_schedule
    first = console_schedule(name: "First paused")
    second = console_schedule(name: "Second paused")
    [first, second].each { |job| job.update!(status: "paused", next_run_at: nil) }
    hidden = schedule_conversation(creating_user: users(:owner), access_default: "none")
    console_schedule(conversation: hidden)
    paths = ["/agent_api/v1/schedules", "/agent_api/v1/workspaces/#{@workspace.public_id}/schedules",
      "#{conversation_path(@conversation)}/schedules"]

    paths.each do |path|
      get path, headers: auth, params: { status: "paused", limit: 1 }
      assert_response :success
      row = response.parsed_body.fetch("schedules").sole
      assert_equal first.public_id, row.fetch("public_id")
      assert_equal @workspace.public_id, row.fetch("workspace_public_id")
      cursor = response.parsed_body.dig("pagination", "next_after")
      assert cursor
      assert_not_includes cursor, first.public_id
      get path, headers: auth, params: { status: "paused", limit: 1, after: cursor }
      assert_response :success
      assert_equal second.public_id, response.parsed_body.fetch("schedules").sole.fetch("public_id")
      assert_nil response.parsed_body.dig("pagination", "next_after")
    end

    get "/agent_api/v1/schedules", headers: auth, params: { workspace_public_id: @workspace.public_id, status: "active" }
    assert_response :success
    assert_equal [active.public_id], response.parsed_body.fetch("schedules").map { |row| row.fetch("public_id") }
    get "/agent_api/v1/schedules", headers: auth, params: { workspace_public_id: workspaces(:personal).public_id }
    assert_response :not_found
  end

  test "global listing conceals tombstones, inaccessible workspaces and conversations even from administrators" do
    concealed = console_schedule(conversation: schedule_conversation(access_default: "none"))
    deleted = schedule_conversation
    console_schedule(conversation: deleted)
    deleted.update!(tombstoned_at: Time.current)
    private_workspace = workspaces(:personal)
    private_agent = create_agent_member(steward: users(:curator))
    private_conversation = schedule_conversation(workspace: private_workspace, creating_user: users(:curator), answering_user: private_agent)
    console_schedule(conversation: private_conversation)
    @token = create_access_token_fixture(user: users(:owner), name: "Admin member plane")

    get "/agent_api/v1/schedules", headers: auth
    assert_response :success
    assert_empty response.parsed_body.fetch("schedules")
    assert_not_includes response.body, concealed.public_id
  end

  test "the global list keeps the member credential plane and pagination limits" do
    console_schedule
    get "/agent_api/v1/schedules"
    assert_response :unauthorized
    platform = create_access_token_fixture(user: @human, name: "Platform", plane: :platform)
    get "/agent_api/v1/schedules", headers: { "Authorization" => "Bearer #{platform.secret}" }
    assert_response :unauthorized
    [0, 101].each do |limit|
      get "/agent_api/v1/schedules", headers: auth, params: { limit: limit }
      assert_response :bad_request
    end
    get "/agent_api/v1/schedules", headers: auth, params: { status: "unknown" }
    assert_response :bad_request
    get "/agent_api/v1/schedules", headers: auth
    assert_response :success
  end

  test "adding schedules does not add one context query per row" do
    console_schedule
    get "/agent_api/v1/schedules", headers: auth
    one = sql_count { get "/agent_api/v1/schedules", headers: auth }
    8.times { console_schedule(conversation: schedule_conversation) }
    many = sql_count { get "/agent_api/v1/schedules", headers: auth }
    assert_response :success
    assert_equal 9, response.parsed_body.fetch("schedules").size
    assert_operator many, :<=, one + 1
  end
end
