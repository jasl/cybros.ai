require "test_helper"

class AgentsAPIKeysTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:member)
    sign_in_as @owner
  end

  test "a steward creates an Agent and manages separate one-time member and executor keys" do
    get new_agent_path
    assert_response :success
    assert_select "input[name='agent[display_name]']"
    assert_select "input[name='agent[agent_identifier]']", count: 0
    post agents_path, params: { agent: { display_name: "Console application" } }
    agent = @owner.stewarded_agents.find_by!(display_name: "Console application")
    assert_redirected_to agent_path(agent)
    follow_redirect!
    assert_select "a[href=?]", agent_api_keys_path(agent)
    assert_select "a[href=?]", agent_executor_api_keys_path(agent)
    assert_select "a[href*='/private_runners']", count: 0
    get new_agent_api_key_path(agent)
    assert_response :success
    assert_select "form[data-turbo='false']"
    post agent_api_keys_path(agent), params: { api_key: { name: "Console member" } }
    assert_response :created
    assert_includes response.headers["Cache-Control"], "no-store"
    secret = css_select("input[name='api_key_secret']").sole["value"]
    token = AccessToken.authenticate_token(secret)
    assert_equal agent, token.user
    get agent_api_keys_path(agent)
    assert_response :success
    assert_not_includes response.body, secret
    assert_select "tr[data-api-key-id=?]", token.public_id
    post agent_api_key_revocation_path(agent, token)
    assert_redirected_to agent_api_keys_path(agent)
    assert_nil AccessToken.authenticate_token(secret)
    get new_agent_executor_api_key_path(agent)
    assert_response :success
    post agent_executor_api_keys_path(agent), params: { api_key: { name: "Executor" } }
    assert_response :created
    get agent_path(agent)
    assert_response :success
    assert_select "p", text: "API keys issued for this registration"
  end



  test "invalid names render their owning forms and removed Agents refuse issuance" do
    post agents_path, params: { agent: { display_name: "" } }
    assert_response :unprocessable_entity
    assert_select "p.field-error", text: /blank/
    agent = @owner.build_agent(display_name: "Application")
    agent.save!
    post agent_api_keys_path(agent), params: { api_key: { name: "" } }
    assert_response :unprocessable_entity
    assert_select "p.field-error", text: /blank/
    agent.remove
    post agent_api_keys_path(agent), params: { api_key: { name: "Removed" } }
    assert_response :unprocessable_entity
    assert_select "[role='alert']", text: I18n.t("agents.api_keys.not_issuable")
  end
end
