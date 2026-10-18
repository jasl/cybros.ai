require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"
require_relative "../../../support/mcp_test_server"

# Public configuration and input doors, the ordinary model/scheduler chain,
# and an independent HTTP MCP peer. Only model inference is deterministic.
class AgentAPI::V1::McpExecutionTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper
  include InvocationHarness
  include RunLaneTestHelper

  test "an owner's connected tool runs through approval and returns to the model without an executor loop" do
    agent = users(:agent)
    platform = create_access_token_fixture(user: agent.steward, name: "Connections", plane: :platform)
    member = connect_agent_session(steward: agent.steward, agent_identifier: agent.agent_identifier).access_secret
    agent_auth = { "Authorization" => "Bearer #{member}" }
    server = mcp_server
    session = HTTPX.plugin(:ssrf_filter, safe_private_ranges: ["127.0.0.1/32"])
    post "/api/v1/mcp_connections", headers: bearer(platform), as: :json, params: { mcp_connection: {
      name: "Work notes", account_label: "Work", endpoint_url: server.endpoint_url,
      auth_type: "bearer", bearer_token: "fixture-mcp-secret",
    } }
    assert_response :created
    connection = response.parsed_body.fetch("mcp_connection")
    connection_path = "/api/v1/mcp_connections/#{connection.fetch("public_id")}"
    HTTPX.stub(:plugin, session) do
      post "#{connection_path}/catalog_refresh", headers: bearer(platform), as: :json,
        params: { command: { lock_version: connection.fetch("lock_version") } }
    end
    assert_response :success
    connection = response.parsed_body.fetch("mcp_connection")
    put "/agent_api/v1/profile/configuration", headers: agent_auth, as: :json, params: { configuration: {
      approval_mode: "ask", default_model: "dev/mock-text",
      mcp_tools: [{ connection_public_id: connection.fetch("public_id"), tool_name: "write", name: "work_write" }],
    } }
    assert_response :success
    get "/agent_api/v1/mcp_connections", headers: agent_auth
    assert_response :success
    assert_includes response.body, "Work notes"
    refute_includes response.body, "fixture-mcp-secret"

    post conversations_path, headers: agent_auth.merge("Idempotency-Key" => "mcp-conversation"), as: :json, params: { conversation: {
      title: "Save a note", answering_user_public_id: agent.public_id,
    } }
    assert_response :created
    conversation = Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))
    post inputs_path(conversation), headers: agent_auth.merge("Idempotency-Key" => "mcp-input"), as: :json, params: { input: {
      kind: "direct_reply", text: "Save hello in my work account", model: { model: "dev/mock-text" },
    } }
    assert_response :accepted
    input_public_id = response.parsed_body.fetch("input").fetch("public_id")
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    get inputs_path(conversation), headers: auth
    assert_response :success
    assert_empty response.parsed_body.fetch("inputs"), response.body
    get "#{inputs_path(conversation)}/#{input_public_id}/materialization", headers: auth
    assert_response :success
    materialization = response.parsed_body.fetch("materialization")
    turn = conversation.turns.sole
    run = turn.active_variant.run
    assert_nil run.default_runner_executor_id
    schedule_loop!(run)
    run_loop_round!(run, sse_success("Saving the note", tool_calls: [
      { id: "write-note", name: "work_write", arguments: JSON.generate(value: "hello") },
    ]))
    task = run.tasks.find_by!(tool_call_id: "write-note")
    assert_equal "needs_approval", task.status
    assert_equal "model", task.authored_by
    assert_empty tool_requests(server)

    run_path = "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{run.public_id}"
    get "#{run_path}/tasks/#{task.node_key}", headers: auth
    assert_response :success
    assert_equal "mcp", response.parsed_body.dig("task", "target", "kind")
    assert_equal connection.fetch("public_id"), response.parsed_body.dig("task", "target", "connection_public_id")
    assert_equal McpConnection::EFFECT_PROFILE, response.parsed_body.dig("task", "effect_profile")
    post "#{run_path}/tasks/#{task.node_key}/approve", headers: auth
    assert_response :success
    HTTPX.stub(:plugin, session) { perform_enqueued_jobs only: Runs::McpToolJob }
    assert_equal "completed", task.reload.status
    assert_nil task.addressed_executor_id
    assert_nil task.claimed_at
    assert_equal({ "name" => "write", "arguments" => { "value" => "hello" } },
      tool_requests(server).sole.fetch(:body).fetch("params").except("_meta"))
    assert_equal "Bearer fixture-mcp-secret", tool_requests(server).sole.fetch(:headers).fetch("authorization")

    schedule_loop!(run)
    attempt = loop_attempt(run)
    built = build(attempt)
    assert_predicate built, :built?
    request_entries = sealed_request_entries(attempt.model_invocation)
    assert_includes request_entries.to_json, "note-42"
    refute_includes request_entries.to_json, "fixture-mcp-secret"
    apply_via(attempt, sse_success("Saved note-42 in your work account"))
    Runs::ConvergeTerminalSteps.call
    schedule_loop!(run)
    Conversations::Turns::Converge.call
    get "#{conversation_path(conversation)}/history", headers: auth, params: { include_execution: true }
    assert_response :success
    assert_includes response.body, "Saved note-42 in your work account"
    assert_equal "completed", turn.reload.status
    get "#{inputs_path(conversation)}/#{input_public_id}/materialization", headers: auth
    assert_response :success
    assert_equal materialization, response.parsed_body.fetch("materialization")
    assert_equal 1, tool_requests(server).length
  ensure
    server&.close
  end

  private

    def bearer(token) = { "Authorization" => "Bearer #{token.secret}" }
    def tool_requests(server) = server.requests.select { |request| request.dig(:body, "method") == "tools/call" }

    def mcp_server
      McpTestServer.new do |request|
        rpc = request.fetch(:body)
        result = case rpc.fetch("method")
        when "server/discover"
          { supportedVersions: ["2026-07-28"], capabilities: { tools: {} }, ttlMs: 0, cacheScope: "private" }
        when "tools/list"
          { tools: [{ name: "write", description: "Save a note", inputSchema: { type: "object",
            properties: { value: { type: "string" } }, required: ["value"] } }] }
        when "tools/call"
          { content: [{ type: "text", text: "Saved note-42" }], structuredContent: { id: "note-42" } }
        else
          flunk "unexpected MCP method: #{rpc.fetch("method")}"
        end
        { json: { jsonrpc: "2.0", id: rpc.fetch("id"), result: result } }
      end
    end
end
