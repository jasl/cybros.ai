require "test_helper"

class AgentResourcesTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:member)
    sign_in_as @owner
    @connection = connect_agent_session(steward: @owner, agent_identifier: "console.resources", display_name: "My application")
    @agent = @connection.access_token.user
    @named = Users::DeclareNamedAgent.call(caller: @agent, name: "reviewer", scope: "steward",
      description: "Review changes", configuration: { prompt_mechanism: "default", approval_mode: "bypass",
        tool_definitions: [], approval_rules: nil, prompt_template: nil, compaction_policy: nil, default_model: nil,
        kernel_tools: ["nexus.memory.read"] }).user
  end

  test "detail offers declaration and scoped work without inventing named credentials" do
    get agent_path(@named)

    assert_response :success
    assert_select "a[href=?]", agent_configuration_path(@named), text: "Agent configuration"
    assert_select "a[href^='/conversations/new']", count: 0
    assert_select "a[href=?]", agent_work_report_path(@named)
    assert_select "[data-address-id]", count: 0
    assert_select "[data-application-executor-id=?]", @connection.executor_access_token.executor.public_id do
      assert_select "dd", text: "My application"
      assert_select "dd", text: "Ready"
    end
    assert_select "p", text: "No application connected", count: 0
    assert_select "body", text: /This Agent shares its application's connection and API keys/
    assert_select "a[href=?]", agent_api_keys_path(@named), count: 0
  end

  test "configuration is directly readable and escapes the Agent's own prompt text" do
    @named.update!(default_model: "retired/unavailable")
    @named.with_lock do
      PromptDocuments::Write.call(anchor: { user: @named }, slot: "system_prompt", content: "<script>own prompt</script>")
    end
    @agent.with_lock do
      PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt", content: "Parent private prompt")
    end

    get agent_configuration_path(@named)

    assert_response :success
    assert_select "h1", text: "Agent configuration"
    assert_select "dd", text: "retired/unavailable"
    assert_select "dd", text: "Nexus defaults"
    assert_select "dd", text: "Allow without asking"
    assert_select "[data-prompt-slot=system_prompt] pre", text: "<script>own prompt</script>"
    assert_select "script", text: "own prompt", count: 0
    assert_not_includes response.body, "Parent private prompt"
    assert_select "form[action=?]", agent_configuration_path(@named), count: 0
  end

  test "Agent directory finds removed Agents by handle and stays within the manager's Agents" do
    @named.update!(handle: "reviewer-renamed")
    @named.remove

    get agents_path, params: { query: "@REVIEWER-RENAMED", status: "removed" }

    assert_response :success
    assert_select "[data-agent-id]", count: 1
    assert_select "[data-agent-id=?]", @named.public_id
    assert_select "a[href=?]", agent_path(@named), text: @named.display_name
    assert_select "input[name=query][value='@REVIEWER-RENAMED'][maxlength='100']"
    assert_select "select[name=status] option[selected][value=removed]"

    get agent_path(@named)
    assert_select "form[action=?]", agent_restoration_path(@named)

    get agents_path, params: { query: users(:agent).display_name }
    assert_select "[data-agent-id=?]", users(:agent).public_id, count: 0

    get agents_path, params: { query: "reviewer-renamed", status: "active" }
    assert_select "[data-agent-id]", count: 0
    assert_select "body", text: /No matching Agents/
  end

  test "Agent search escapes wildcards and pagination retains filters" do
    @agent.update!(display_name: "Match_100%")
    @named.update!(display_name: "MatchZ100more")
    get agents_path, params: { query: "_100%" }
    assert_select "[data-agent-id]", count: 1
    assert_select "[data-agent-id=?]", @agent.public_id

    11.times do |index|
      create_agent_member(steward: @owner, agent_identifier: "directory-#{index}", display_name: "Directory #{index}")
    end
    get agents_path, params: { query: "Directory", status: "active" }
    assert_select "[data-agent-id]", count: 10
    assert_select "nav a[href*='page=2'][href*='query=Directory'][href*='status=active']"
    get agents_path, params: { query: "Directory", status: "active", page: 2 }
    assert_select "[data-agent-id]", count: 1
  end

  test "a non-steward administrator cannot read configuration" do
    sign_out
    sign_in_as users(:owner)

    get agent_configuration_path(@named)
    assert_response :not_found
  end
end
