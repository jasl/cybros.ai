require "test_helper"

class API::V1::AgentsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:member)
    post api_v1_session_path, params: { email: @owner.identity.email, password: "password" }, as: :json
    @headers = { "Authorization" => "Bearer #{response.parsed_body.fetch("token")}" }
    @agent = @owner.build_agent(display_name: "Application")
    @agent.save!
    @path = "/api/v1/agents/#{@agent.public_id}"
  end

  test "a Human creates an opaque Agent identity without selecting its registration key" do
    post "/api/v1/agents", params: { agent: { display_name: "Created", agent_identifier: "chosen", role: "owner" } }, headers: @headers, as: :json

    assert_response :created
    row = User.find_by!(public_id: response.parsed_body.dig("agent", "public_id"))
    assert_equal @owner, row.steward
    assert_predicate row, :agent_member?
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, row.agent_identifier)
    assert_equal row.agent_identifier, response.parsed_body.dig("agent", "agent_identifier")
    assert_nil Executor.address_for(row)
    collection = row.memory_collections.where(is_default: true, speaker: nil).sole
    assert_equal :agent, collection.natural_scope
    assert_equal row.account, collection.account
    get "/api/v1/agents", headers: @headers
    assert_response :success
    assert_includes response.parsed_body.fetch("agents").map { |item| item.fetch("public_id") }, row.public_id
    assert response.parsed_body.key?("pagination")
  end

  test "member key reveal is one-time and revocation leaves the second key working" do
    first = create_key("#{@path}/api_keys", "First")
    second = create_key("#{@path}/api_keys", "Second")
    get "#{@path}/api_keys", headers: @headers
    assert_response :success
    assert_not_includes response.body, first.fetch("secret")
    assert_not_includes response.body, "secret_digest"
    assert_equal 2, response.parsed_body.fetch("api_keys").size
    post "#{@path}/api_keys/#{first.dig("api_key", "public_id")}/revocation", headers: @headers, as: :json
    assert_response :no_content
    get agent_api_v1_profile_path, headers: bearer(first.fetch("secret"))
    assert_response :unauthorized
    get agent_api_v1_profile_path, headers: bearer(second.fetch("secret"))
    assert_response :success
    assert_equal @agent.agent_identifier, response.parsed_body.dig("member", "agent_identifier")
    assert_nil response.parsed_body.dig("credential", "expires_at")
    post "#{@path}/api_keys", params: { api_key: { name: "Wrong plane" } }, headers: bearer(second.fetch("secret")), as: :json
    assert_response :unauthorized
  end

  test "executor introspection names the application and retired private runner routes are absent" do
    executor = create_key("#{@path}/executor/api_keys", "Executor")
    get agent_api_v1_executor_path, headers: bearer(executor.fetch("secret"))
    assert_response :success
    assert_equal @agent.public_id, response.parsed_body.dig("executor", "agent_public_id")
    assert_nil response.parsed_body.dig("executor", "assignment_scope")
    post "#{@path}/private_runners", params: { private_runner: { display_name: "Laptop" } }, headers: @headers, as: :json
    assert_response :not_found
  end

  test "key and runner routes resolve within their owning Agent and steward" do
    other = users(:owner).build_agent(display_name: "Other steward")
    other.save!
    get "/api/v1/agents/#{other.public_id}", headers: @headers
    assert_response :not_found
    key = create_key("#{@path}/api_keys", "Scoped")
    post "/api/v1/agents/#{other.public_id}/api_keys/#{key.dig("api_key", "public_id")}/revocation", headers: @headers, as: :json
    assert_response :not_found
    get "#{@path}/executor/api_keys", headers: @headers
    assert_empty response.parsed_body.fetch("api_keys")
    post "#{@path}/executor/api_keys/#{key.dig("api_key", "public_id")}/revocation", headers: @headers, as: :json
    assert_response :not_found
  end

  test "connection revocation fences addressless keys and inactive Agents cannot mint" do
    key = create_key("#{@path}/api_keys", "Member")
    post "#{@path}/connection_revocation", headers: @headers, as: :json
    assert_response :success
    assert_nil AccessToken.authenticate_token(key.fetch("secret"))
    post "#{@path}/removal", headers: @headers, as: :json
    assert_response :success
    post "#{@path}/api_keys", params: { api_key: { name: "Removed" } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "not_issuable", response.parsed_body.dig("error", "code")
    post "#{@path}/restoration", headers: @headers, as: :json
    assert_response :success
    assert_nil AccessToken.authenticate_token(key.fetch("secret"))
  end

  test "issuance shares a Human limit across all key kinds and reports the retry delay" do
    routes = ["#{@path}/api_keys", "#{@path}/executor/api_keys"]
    10.times do |index|
      post routes.fetch(index % routes.length), params: { api_key: { name: "Key #{index}" } },
        headers: @headers.merge("REMOTE_ADDR" => "192.0.2.#{index + 1}"), as: :json
      assert_response :created
    end

    assert_no_difference -> { AccessToken.count } do
      post "#{@path}/api_keys", params: { api_key: { name: "One too many" } }, headers: @headers, as: :json
    end
    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body.dig("error", "code")
    assert_equal "180", response.headers["Retry-After"]
  end

  private

    def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

    def create_key(path, name)
      post path, params: { api_key: { name: name } }, headers: @headers, as: :json
      assert_response :created
      assert_equal "no-store", response.headers["Cache-Control"]
      response.parsed_body
    end
end
