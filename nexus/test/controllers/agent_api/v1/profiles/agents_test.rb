require "test_helper"

# THE NAMED DEFINITIONS DOOR: a paired agent profile's bearer mints, replaces, lists and removes its
# own named definitions — `users` rows of kind agent under `<caller identifier>/<name>`, no
# credential, no address. A Human bearer is refused as the configuration door refuses it.
class AgentAPI::V1::Profiles::AgentsTest < ActionDispatch::IntegrationTest
  include RunLaneTestHelper

  setup do
    @owner = users(:owner)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(accounts(:cybros))
    @agent_secret = connect_agent_session(steward: @owner, agent_identifier: @agent.agent_identifier).access_secret
    @steward_secret = create_access_token_fixture(user: @owner, name: "S").secret
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }
  def base = "/agent_api/v1/profile/agents"

  def configuration(tools: [READ_TOOL], default_model: nil, fallback_model: nil)
    {
      tool_definitions: tools, approval_mode: "bypass", approval_rules: nil, prompt_mechanism: "default",
      prompt_template: nil, compaction_policy: { mode: "kernel" }, default_model: default_model,
      fallback_model: fallback_model,
    }
  end

  def declare!(name, secret: @agent_secret, scope: "instance", description: "Reviews a diff for defects.",
               system_prompt: "You are a reviewer.", **body)
    put "#{base}/#{name}", headers: bearer(secret), as: :json,
      params: { scope: scope, description: description, system_prompt: system_prompt,
                configuration: configuration }.merge(body)
  end

  def code = response.parsed_body.dig("error", "code")

  test "PUT mints the caller's named definition: 201, the listing's row, the composed identifier, the name as handle" do
    declare!("reviewer")
    assert_response :created

    row = response.parsed_body.fetch("agent")
    assert_equal "instance", row.fetch("scope")
    assert_equal "reviewer", row.fetch("name")
    assert_equal "reviewer", row.fetch("handle"), "the handle is the name when free in the account"
    assert_equal "reviewer", row.fetch("display_name")
    assert_equal "#{@agent.agent_identifier}/reviewer", row.fetch("agent_identifier")
    assert_equal "agent", row.fetch("kind")
    assert_equal @owner.public_id, row.fetch("steward_public_id")
    assert_equal @agent.public_id, row.fetch("derived_from_public_id")
    assert_equal "Reviews a diff for defects.", row.fetch("description")
    assert_equal %w[read_file], row.dig("configuration", "tool_definitions").map { |t| t.dig("function", "name") }
    assert_equal "bypass", row.dig("configuration", "approval_mode")
    assert_nil row.dig("configuration", "default_model")

    minted = User.find_by!(public_id: row.fetch("public_id"))
    assert_nil minted.identity
    assert_empty minted.access_tokens
    assert_nil TaskExecutor.address_for(minted), "no credential, no address: it answers, it never claims or connects"
    assert_equal "You are a reviewer.", minted.prompt_documents.find_by!(slot: "system_prompt").content
  end

  test "PUT again replaces the same row whole (200) — the scope flips, the handle, id and identifier never move" do
    declare!("reviewer")
    assert_response :created
    first = response.parsed_body.fetch("agent")

    declare!("reviewer", scope: "steward", description: "Reviews.", system_prompt: nil, display_name: "The reviewer")
    assert_response :success
    second = response.parsed_body.fetch("agent")
    assert_equal first.fetch("public_id"), second.fetch("public_id")
    assert_equal first.fetch("handle"), second.fetch("handle")
    assert_equal first.fetch("agent_identifier"), second.fetch("agent_identifier")
    assert_equal "steward", second.fetch("scope")
    assert_equal "The reviewer", second.fetch("display_name")
    assert_equal "Reviews.", second.fetch("description")
    row = User.find_by!(public_id: first.fetch("public_id"))
    assert_not row.prompt_documents.exists?(slot: "system_prompt"), "a nil body deletes the slot"
    assert_equal 1, User.where(derived_from_id: @agent.id).count, "one row per name per instance"
  end

  test "a named definition owns exact Runner import intent independent of its declarer" do
    ids = [SecureRandom.uuid_v7, SecureRandom.uuid_v7]
    declare!("reader", configuration: configuration(tools: []).merge(
      kernel_tools: ["nexus.runners.list"], runner_executor_public_ids: ids, runner_tool_names: ["read"]))
    assert_response :created
    row = response.parsed_body.fetch("agent")
    assert_equal ["nexus.runners.list"], row.dig("configuration", "kernel_tools")
    assert_equal ids, row.dig("configuration", "runner_executor_public_ids")
    assert_equal ["read"], row.dig("configuration", "runner_tool_names")
    assert_nil @agent.reload.runner_executor_public_ids

    declare!("reader", configuration: configuration(tools: []).merge(runner_tool_names: []))
    assert_response :success
    assert_equal [], response.parsed_body.dig("agent", "configuration", "runner_tool_names")
    assert_equal [], response.parsed_body.dig("agent", "configuration", "runner_executor_public_ids")
  end

  test "GET lists the caller's own rows of both scopes and the steward's other published rows, read-only" do
    declare!("reviewer")
    declare!("docs", scope: "steward")
    sibling = connect_agent_session(steward: @owner, agent_identifier: "rho.sibling", display_name: "Sibling")
    declare!("shared", secret: sibling.access_secret, scope: "steward")
    declare!("private", secret: sibling.access_secret)
    # Another steward's published row is not this steward's.
    other = connect_agent_session(steward: users(:member), agent_identifier: "rho.elsewhere", display_name: "Else")
    declare!("elsewhere", secret: other.access_secret, scope: "steward")

    get base, headers: bearer(@agent_secret)
    assert_response :success
    rows = response.parsed_body.fetch("agents")
    assert_equal %w[docs reviewer shared], rows.map { |row| row.fetch("name") }, "ordered by display name"
    shared = rows.find { |row| row.fetch("name") == "shared" }
    assert_equal "steward", shared.fetch("scope")
    assert_equal sibling.access_token.user.public_id, shared.fetch("derived_from_public_id")

    delete "#{base}/shared", headers: bearer(@agent_secret)
    assert_response :not_found, "a sibling's published row is not this caller's to remove"
    declare!("shared")
    assert_response :created, "the same NAME under this caller is its own row, a different identifier"
    assert_equal "shared-2", response.parsed_body.dig("agent", "handle"), "the kernel's -N rule past the sibling's"
  end

  test "DELETE removes the caller's own row of that name (204) and a later PUT restores the SAME row" do
    declare!("reviewer")
    public_id = response.parsed_body.dig("agent", "public_id")

    delete "#{base}/reviewer", headers: bearer(@agent_secret)
    assert_response :no_content
    row = User.find_by!(public_id: public_id)
    assert_predicate row, :removed?
    assert_equal "reviewer", row.handle, "removal keeps the handle so the restore keeps the word"

    get base, headers: bearer(@agent_secret)
    assert_empty response.parsed_body.fetch("agents"), "a removed row is not listed"
    delete "#{base}/reviewer", headers: bearer(@agent_secret)
    assert_response :not_found
    assert_equal "not_found", code

    declare!("reviewer")
    assert_response :success, "restored, not minted: 200"
    assert_equal public_id, response.parsed_body.dig("agent", "public_id")
    assert_predicate row.reload, :active?
  end

  # Refusals preserve named-definition ownership and the agent-only configuration boundary.

  test "a Human bearer is not an agent profile: 403 on every action" do
    get base, headers: bearer(@steward_secret)
    assert_response :forbidden
    assert_equal "not_agent", code
    declare!("reviewer", secret: @steward_secret)
    assert_response :forbidden
    assert_equal "not_agent", code
    delete "#{base}/reviewer", headers: bearer(@steward_secret)
    assert_response :forbidden
    assert_equal "not_agent", code
  end

  test "scope, description and configuration are required: 400 parameter_missing" do
    put "#{base}/reviewer", headers: bearer(@agent_secret), as: :json,
      params: { description: "x", configuration: configuration }
    assert_response :bad_request
    assert_equal "parameter_missing", code
    put "#{base}/reviewer", headers: bearer(@agent_secret), as: :json,
      params: { scope: "instance", configuration: configuration }
    assert_response :bad_request
    put "#{base}/reviewer", headers: bearer(@agent_secret), as: :json,
      params: { scope: "instance", description: "x" }
    assert_response :bad_request
    assert_equal 0, User.where(derived_from_id: @agent.id).count
  end

  test "a segment outside the handle grammar is a route miss: 404, a dotted name included" do
    ["Reviewer", "reviewer.md", "a", "has%20space"].each do |segment|
      put "#{base}/#{segment}", headers: bearer(@agent_secret), as: :json,
        params: { scope: "instance", description: "x", configuration: configuration }
      assert_response :not_found, segment
    end
  end

  test "a PAIRED program holding the composed identifier is 409 identifier_taken, untouched" do
    paired = create_agent_member(steward: @owner, display_name: "Paired", agent_identifier: "#{@agent.agent_identifier}/reviewer")

    declare!("reviewer")
    assert_response :conflict
    assert_equal "identifier_taken", code
    assert_nil paired.reload.definition_scope
    assert_nil paired.derived_from_id
    assert_equal "Paired", paired.display_name
  end

  test "a removed row whose steward's generation moved cannot be restored: 409 shutdown_pending" do
    declare!("reviewer")
    row = User.find_by!(public_id: response.parsed_body.dig("agent", "public_id"))
    delete "#{base}/reviewer", headers: bearer(@agent_secret)
    assert_response :no_content
    User.where(id: row.id).update_all(applied_steward_shutdown_generation: @owner.managed_resource_shutdown_generation - 1)

    declare!("reviewer")
    assert_response :conflict
    assert_equal "shutdown_pending", code
    assert_predicate row.reload, :removed?
  end

  test "validation refusals are 422 naming the field: the scope word, the description's shape, the identifier's length, the seven columns' own" do
    declare!("reviewer", scope: "global")
    assert_response :unprocessable_entity
    assert_equal "validation_failed", code
    assert_match(/scope/i, response.parsed_body.dig("error", "message"))

    declare!("reviewer", description: "  ")
    assert_response :unprocessable_entity
    assert_match(/description/i, response.parsed_body.dig("error", "message"))
    declare!("reviewer", description: "two\nlines")
    assert_response :unprocessable_entity
    assert_match(/description/i, response.parsed_body.dig("error", "message"))
    declare!("reviewer", description: "x" * 1025)
    assert_response :unprocessable_entity
    assert_match(/description/i, response.parsed_body.dig("error", "message"))
    declare!("reviewer", description: "é" * 1024)
    assert_response :created, "1024 CHARACTERS, not bytes"

    long = connect_agent_session(steward: @owner, agent_identifier: "p" * 120, display_name: "Long")
    declare!("reviewer", secret: long.access_secret)
    assert_response :unprocessable_entity
    assert_match(/identifier/i, response.parsed_body.dig("error", "message"))

    put "#{base}/model", headers: bearer(@agent_secret), as: :json,
      params: { scope: "instance", description: "x", configuration: configuration(default_model: "sonnet") }
    assert_response :unprocessable_entity
    assert_match(/default model.*\(unknown_model\)/i, response.parsed_body.dig("error", "message"))
    put "#{base}/mode", headers: bearer(@agent_secret), as: :json,
      params: { scope: "instance", description: "x", configuration: configuration.merge(approval_mode: nil) }
    assert_response :unprocessable_entity
    assert_match(/approval mode/i, response.parsed_body.dig("error", "message"))
    assert_equal ["reviewer"], User.where(derived_from_id: @agent.id).map(&:display_name)
  end

  test "a body naming a macro outside the registry is the prompt door's word, and nothing is minted" do
    declare!("reviewer", system_prompt: "You are {{nobody}}.")
    assert_response :unprocessable_entity
    assert_equal "prompt_document_macro_unknown", code
    assert_equal 0, User.where(derived_from_id: @agent.id).count, "one transaction: the refused slot takes the row with it"
  end

  test "the file's model becomes the row's default_model, judged at declaration (F-3 step 0)" do
    put "#{base}/strong", headers: bearer(@agent_secret), as: :json,
      params: { scope: "instance", description: "Strong.", configuration: configuration(default_model: "dev/mock-text") }
    assert_response :created
    assert_equal "dev/mock-text", response.parsed_body.dig("agent", "configuration", "default_model")
  end

  # A definition carries the whole shape, the model a declined step re-runs on included, judged at
  # declaration as the profile door judges it.
  test "the file's fallback becomes the row's fallback_model, judged at declaration" do
    put "#{base}/strong", headers: bearer(@agent_secret), as: :json, params: {
      scope: "instance", description: "Strong.",
      configuration: configuration(default_model: "dev/mock-text", fallback_model: "dev/mock-unmetered"),
    }
    assert_response :created
    assert_equal "dev/mock-unmetered", response.parsed_body.dig("agent", "configuration", "fallback_model")

    put "#{base}/weak", headers: bearer(@agent_secret), as: :json,
      params: { scope: "instance", description: "Weak.", configuration: configuration(fallback_model: "sonnet") }
    assert_response :unprocessable_entity
    assert_match(/fallback model.*\(unknown_model\)/i, response.parsed_body.dig("error", "message"))
  end
end
