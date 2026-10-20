require "test_helper"

class AgentAPI::V1::RunCandidatesTest < ActionDispatch::IntegrationTest
  setup do
    @human, @agent, @workspace = users(:member), users(:agent), workspaces(:shared)
    @headers = { "Authorization" => "Bearer #{create_access_token_fixture(user: @human, name: "candidates").secret}" }
  end

  test "empty windows advance, archived original runs survive, and the ceiling ends a round" do
    50.times { Run.create!(workspace: @workspace, creating_user: @agent, status: "pending", approval_mode: "bypass") }
    run = hosted_run
    run.conversation.update!(archived_at: Time.current)
    get "/agent_api/v1/run_candidates", headers: @headers, params: { agent_public_id: @agent.public_id }
    assert_response :success
    assert_empty response.parsed_body.fetch("runs")
    cursor = response.parsed_body.dig("pagination", "next_after")
    assert cursor
    later = hosted_run
    get "/agent_api/v1/run_candidates", headers: @headers, params: { agent_public_id: @agent.public_id, after: cursor }
    assert_response :success
    assert_equal [{ "public_id" => run.public_id, "workspace_public_id" => @workspace.public_id,
      "conversation_public_id" => run.conversation.public_id, "turn_public_id" => run.turn.public_id,
      "status" => "running" }], response.parsed_body.fetch("runs")
    assert_nil response.parsed_body.dig("pagination", "next_after")
    get "/agent_api/v1/run_candidates", headers: @headers, params: { agent_public_id: users(:owner).public_id, after: cursor }
    assert_response :bad_request
    get "/agent_api/v1/run_candidates", headers: @headers, params: { agent_public_id: @agent.public_id, after: "broken" }
    assert_response :bad_request
    other_headers = { "Authorization" => "Bearer #{create_access_token_fixture(user: users(:owner), name: "other-candidates").secret}" }
    get "/agent_api/v1/run_candidates", headers: other_headers, params: { agent_public_id: @agent.public_id, after: cursor }
    assert_response :bad_request
    assert_operator later.id, :>, run.id
  end

  test "bounded associations preserve ordinary read permissions and do not issue per row ACL reads" do
    visible = 8.times.map { hosted_run }
    hidden = hosted_run(access_default: "none")
    denied = hosted_run
    denied.conversation.conversation_access_entries.create!(user: @human, level: "none")
    personal = hosted_run(workspace: workspaces(:personal))
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:sql].start_with?("SELECT") }
    page = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      Runs::Candidates.new(user: @human, agent_public_id: @agent.public_id).call
    end
    assert_equal visible.map(&:public_id), page.runs.map(&:public_id)
    assert_equal 1, queries.count { |sql| sql.include?('FROM "conversation_access_entries"') }
    assert_operator queries.length, :<=, 8
    assert_equal Run.visible_to(@human).for_agent(@agent.public_id).pluck(:public_id).sort, page.runs.map(&:public_id).sort
    assert_empty page.runs.map(&:public_id) & [hidden, denied, personal].map(&:public_id)
  end

  private

    def hosted_run(workspace: @workspace, access_default: "full")
      conversation = Conversation.create!(workspace: workspace, creating_user: @agent, answering_user: @agent,
        title: "Recovery", access_default: access_default)
      create_run_backed_turn(conversation: conversation, acting_user: @agent).run.tap { |run| run.update!(status: "running") }
    end
end
