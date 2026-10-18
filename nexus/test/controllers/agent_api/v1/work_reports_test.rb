require "test_helper"

class AgentAPI::V1::WorkReportsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @token = create_access_token_fixture(user: @human, name: "Work statistics")
    @headers = { "Authorization" => "Bearer #{@token.secret}" }
    @window = { from: "2026-10-10T00:00:00Z", to: "2026-10-12T00:00:00Z", unit: "day" }
    @run = Run.create!(workspace: workspaces(:shared), creating_user: @human,
      status: "running", approval_mode: "bypass", created_at: Time.utc(2026, 10, 11))
  end

  test "member reports expose bounded public metrics and the same workspace permission funnel" do
    get "/agent_api/v1/work_report", headers: @headers, params: @window
    assert_response :success
    report = response.parsed_body.fetch("report")
    assert_equal 1, report.dig("totals", "created_runs")
    assert_equal 0, report.dig("totals", "active_answering_agents")
    assert_equal 1, report.dig("current", "run_counts", "running")
    assert_equal 2, report.fetch("series").length
    assert_equal "2026-10-08T00:00:00Z", report.dig("previous", "from")
    assert report.fetch("as_of")
    assert_nil report.fetch("workspace_public_id")
    assert_nil report.fetch("agent_public_id")
    assert_not_includes response.body, @run.public_id
    assert_not_includes response.body, "account_id"
    get "/agent_api/v1/work_report", headers: @headers,
      params: @window.merge(workspace_public_id: workspaces(:personal).public_id)
    assert_response :not_found
  end

  test "agent reports apply the same content scope without requiring stewardship" do
    Run.create!(workspace: workspaces(:shared), creating_user: users(:agent),
      status: "running", approval_mode: "bypass", created_at: Time.utc(2026, 10, 11))
    get "/agent_api/v1/work_report", headers: @headers, params: @window.merge(agent_public_id: users(:agent).public_id)
    assert_response :success
    assert_equal users(:agent).public_id, response.parsed_body.dig("report", "agent_public_id")
    assert_equal 1, response.parsed_body.dig("report", "totals", "created_runs")
    get "/agent_api/v1/work_report", headers: @headers, params: @window.merge(agent_public_id: @human.public_id)
    assert_response :not_found
    get "/agent_api/v1/work_report", headers: @headers, params: @window.merge(agent_public_id: [users(:agent).public_id])
    assert_response :bad_request
  end

  test "invalid window scalars and unaligned windows refuse instead of widening" do
    [@window.merge(from: [@window[:from]]), @window.merge(unit: ["day"]),
      @window.merge(workspace_public_id: [workspaces(:shared).public_id]), @window.except(:from),
      @window.merge(from: "yesterday"), @window.merge(from: "2026-10-10T00:30:00Z")].each do |query|
      get "/agent_api/v1/work_report", headers: @headers, params: query
      assert_response :bad_request
    end
    get "/agent_api/v1/work_report", headers: @headers, params: @window.merge(unit: "month")
    assert_response :bad_request
    assert_equal "unit_unsupported", response.parsed_body.dig("error", "code")
  end

  test "default periods use complete UTC days and browser sessions cannot authenticate the member API" do
    travel_to Time.utc(2026, 10, 16, 9, 20) do
      get "/agent_api/v1/work_report", headers: @headers
      assert_response :success
      assert_equal "2026-10-09T00:00:00Z", response.parsed_body.dig("report", "from")
      assert_equal "2026-10-16T00:00:00Z", response.parsed_body.dig("report", "to")
    end
    sign_in_as @human
    get "/agent_api/v1/work_report", params: @window
    assert_response :unauthorized
    platform = create_access_token_fixture(user: users(:owner), name: "Platform statistics", plane: :platform)
    get "/agent_api/v1/work_report", params: @window, headers: { "Authorization" => "Bearer #{platform.secret}" }
    assert_response :unauthorized
  end
end
