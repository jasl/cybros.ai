require "test_helper"

# The generator/committed-file drift test is necessary but not sufficient:
# these checks bind the shared fixtures to the real controllers and request
# parsers that own each currently shipped wire shape.
class Nexus::ContractProducerTest < ActionDispatch::IntegrationTest
  test "profile, executor, Session, and admin-removal producers match the pack" do
    profiles = contract("profiles.json")
    authorization, = connected_agent_pair
    member_credential = DeviceAuthorizations::Consume.call(
      authorization: authorization.reload
    ).access_secret
    # The fixture's configuration block is a declared one, so the real writer declares it first; the
    # tool bytes are the registry's own, and its `default_model` is judged by the real check —
    # the dev lane on.
    DevModelLane.ensure_enabled!(accounts(:cybros))
    put agent_api_v1_profile_configuration_path,
      params: { configuration: profiles.dig("agent_api", "configuration") },
      headers: bearer(member_credential), as: :json
    assert_response :success
    get agent_api_v1_profile_path, headers: bearer(member_credential)
    assert_response :success
    assert_wire_shape profiles.fetch("agent_api"), response.parsed_body
    assert_equal "agent", response.parsed_body.dig("member", "kind")

    # THE NAMED DEFINITIONS LISTING: the real door mints the fixture's instance row for this caller;
    # a sibling instance under the same steward published the other through the real writer.
    named = profiles.fetch("named_agents_fixture").fetch("agents").index_by { |row| row.fetch("name") }
    reviewer = named.fetch("reviewer")
    put "/agent_api/v1/profile/agents/reviewer",
      params: { scope: reviewer.fetch("scope"), description: reviewer.fetch("description"),
                system_prompt: "You are a reviewer.", configuration: reviewer.fetch("configuration") },
      headers: bearer(member_credential), as: :json
    assert_response :created
    assert_wire_shape reviewer, response.parsed_body.fetch("agent")
    docs = named.fetch("docs")
    sibling = create_agent_member(display_name: "Sibling instance", agent_identifier: "rho.19c0aa77")
    outcome = Users::DeclareNamedDefinition.call(caller: sibling, name: "docs", scope: docs.fetch("scope"),
      description: docs.fetch("description"),
      configuration: docs.fetch("configuration").transform_keys(&:to_sym))
    assert_equal :declared, outcome.outcome
    get "/agent_api/v1/profile/agents", headers: bearer(member_credential)
    assert_response :success
    assert_wire_shape profiles.fetch("named_agents_fixture"), response.parsed_body
    assert_equal %w[docs reviewer], response.parsed_body.fetch("agents").map { |row| row.fetch("name") }
    assert_equal profiles.fetch("definition_scopes").sort,
      response.parsed_body.fetch("agents").map { |row| row.fetch("scope") }.sort

    transport_credential = create_bound_credential(
      executor: task_executors(:address),
      name: "Contract executor"
    )
    get agent_api_v1_executor_path, headers: bearer(transport_credential.secret)
    assert_response :success
    assert_wire_shape contract("task_executors.json").fetch("valid_fixture"), response.parsed_body

    post api_v1_session_path,
      params: { email: identities(:owner).email, password: "password" },
      as: :json
    assert_response :created
    session_body = response.parsed_body
    session_fixture = contract("sessions.json").fetch("valid_create_fixture")
    assert_wire_shape session_fixture, session_body
    assert_equal session_fixture.fetch("token_type"), session_body.fetch("token_type")

    get api_v1_profile_path, headers: bearer(session_body.fetch("token"))
    assert_response :success
    assert_wire_shape profiles.fetch("platform_api_session"), response.parsed_body

    platform = create_access_token_fixture(
      user: users(:owner), name: "Contract platform profile", plane: :platform
    )
    get api_v1_profile_path, headers: bearer(platform.secret)
    assert_response :success
    assert_wire_shape profiles.fetch("platform_api_token"), response.parsed_body
    assert_equal profiles.dig("platform_api_token", "credential_plane"),
      response.parsed_body.fetch("credential_plane")

    post "/api/v1/admin/users/#{users(:member).public_id}/removal",
      headers: bearer(session_body.fetch("token")),
      as: :json
    assert_response :success
    admin_fixture = contract("admin_users.json").fetch("valid_removal_fixture")
    assert_wire_shape admin_fixture, response.parsed_body
    %w[kind role status].each do |field|
      assert_equal admin_fixture.dig("user", field), response.parsed_body.dig("user", field)
    end
  end

  test "OAuth authorization and token producers match both success shapes" do
    oauth = contract("oauth.json")
    host! "nexus.example"
    post oauth_device_authorization_path,
      params: oauth.fetch("agent_authorization_request"),
      as: :json
    assert_response :success
    assert_wire_shape oauth.fetch("valid_device_authorization_fixture"), response.parsed_body

    _authorization, agent_code = connected_agent_pair
    post oauth_token_path,
      params: oauth.fetch("device_token_request").merge("device_code" => agent_code),
      as: :json
    assert_response :success
    assert_wire_shape oauth.fetch("valid_agent_token_fixture"), response.parsed_body
    assert_equal "member", response.parsed_body["plane"]

    runner_code = connected_runner_code
    post oauth_token_path,
      params: oauth.fetch("device_token_request").merge("device_code" => runner_code),
      as: :json
    assert_response :success
    assert_wire_shape oauth.fetch("valid_runner_token_fixture"), response.parsed_body
    assert_equal "executor_transport", response.parsed_body["plane"]
    refute response.parsed_body.key?("executor_access_token")

    # The combined shape (r-modes M2): the member-led agent body plus the
    # nested runner lineage — the pack's third token fixture.
    combined_code = connected_combined_code
    post oauth_token_path,
      params: oauth.fetch("device_token_request").merge("device_code" => combined_code),
      as: :json
    assert_response :success
    assert_wire_shape oauth.fetch("valid_combined_token_fixture"), response.parsed_body
    assert_equal "member", response.parsed_body["plane"]
    assert_wire_shape oauth.dig("valid_combined_token_fixture", "runner"), response.parsed_body.fetch("runner")
  end

  test "unknown OAuth request fixtures are rejected by the real token endpoint" do
    oauth = contract("oauth.json")
    host! "nexus.example"

    post oauth_token_path, params: oauth.fetch("unknown_client_request"), as: :json
    assert_equal 400, response.status
    assert_equal "invalid_client", response.parsed_body.fetch("error")

    post oauth_token_path, params: oauth.fetch("unknown_grant_request"), as: :json
    assert_equal 400, response.status
    assert_equal "unsupported_grant_type", response.parsed_body.fetch("error")
  end

  test "machine cancellation's consumed winner matches the terminal fixture" do
    oauth = contract("oauth.json")
    authorization, device_code = connected_agent_pair
    assert_equal :minted,
      DeviceAuthorizations::Consume.call(authorization: authorization.reload).outcome

    request = oauth.fetch("cancellation_request").merge("device_code" => device_code)
    post oauth_device_authorization_cancellation_path, params: request, as: :json

    fixture = oauth.fetch("consumed_cancellation_fixture")
    assert_equal fixture.fetch("status"), response.status
    assert_equal fixture.fetch("body"), response.parsed_body
    assert_predicate authorization.reload, :consumed?
  end

  test "stable error-family fixtures match their real producers" do
    get api_v1_profile_path
    assert_contract_error "errors.json"

    post api_v1_session_path,
      params: { email: identities(:member).email, password: "wrong" },
      as: :json
    assert_contract_error "sessions.json"

    host! "nexus.example"
    post oauth_device_authorization_path,
      params: contract("oauth.json").fetch("agent_authorization_request"),
      as: :json
    assert_response :success
    post oauth_token_path,
      params: contract("oauth.json").fetch("device_token_request").merge(
        "device_code" => response.parsed_body.fetch("device_code")
      ),
      as: :json
    assert_contract_error "oauth.json"

    credential = create_access_token_fixture(user: users(:owner), name: "Contract errors")
    headers = bearer(credential.secret)

    workspace = create_workspace(headers, key: "contract-transition-error")
    Workspace.find_by!(public_id: workspace.fetch("public_id")).update_columns(state: "archiving")
    lifecycle_request = deep_copy(contract("workspaces.json").fetch("valid_lifecycle_request"))
    lifecycle_request.dig("command")["lock_version"] = workspace.fetch("lock_version")
    post "/agent_api/v1/workspaces/#{workspace.fetch("public_id")}/restoration",
      params: lifecycle_request, headers: headers, as: :json
    assert_contract_error "workspaces.json"

    store_workspace = create_workspace(headers, key: "contract-store-error")
    store_path =
      "/agent_api/v1/workspaces/#{store_workspace.fetch("public_id")}/store_entries"
    store_request = contract("store_entries.json").fetch("valid_create_request")
    post store_path, params: store_request,
      headers: headers.merge("Idempotency-Key" => "contract-store-error-first"),
      as: :json
    assert_response :created
    post store_path, params: store_request,
      headers: headers.merge("Idempotency-Key" => "contract-store-error-second"),
      as: :json
    assert_contract_error "store_entries.json"

    post api_v1_session_path,
      params: { email: identities(:owner).email, password: "password" },
      as: :json
    assert_response :created
    post "/api/v1/admin/users/#{users(:curator).public_id}/removal",
      headers: bearer(response.parsed_body.fetch("token")),
      as: :json
    assert_contract_error "admin_users.json"
  end

  test "Workspace and StoreEntry request fixtures pass through their real parsers" do
    credential = create_access_token_fixture(user: users(:owner), name: "Contract workspaces")
    headers = bearer(credential.secret)

    workspace = create_workspace(headers, key: "contract-create")
    refute workspace.fetch("dedicated"), "the Human fixture creates an undedicated Workspace"

    authorization, = connected_agent_pair
    agent_credential = DeviceAuthorizations::Consume.call(
      authorization: authorization.reload
    ).access_secret
    create_request = contract("workspaces.json").fetch("valid_create_request")
    refute create_request.fetch("workspace").key?("dedicated")
    post agent_api_v1_workspaces_path,
      params: create_request,
      headers: bearer(agent_credential).merge("Idempotency-Key" => "contract-agent-create"),
      as: :json
    assert_response :created
    assert response.parsed_body.dig("workspace", "dedicated"),
      "the authenticated Agent is the sole dedication input"

    update_request = deep_copy(contract("workspaces.json").fetch("valid_update_request"))
    update_request.dig("workspace")["lock_version"] = workspace.fetch("lock_version")
    patch "/agent_api/v1/workspaces/#{workspace.fetch("public_id")}",
      params: update_request, headers: headers, as: :json
    assert_response :success
    workspace = response.parsed_body.fetch("workspace")
    assert_equal "Renamed", workspace["name"]

    access_mode_request = deep_copy(contract("workspaces.json").fetch("valid_access_mode_request"))
    access_mode_request.dig("access_mode")["lock_version"] = workspace.fetch("lock_version")
    put "/agent_api/v1/workspaces/#{workspace.fetch("public_id")}/access_mode",
      params: access_mode_request, headers: headers, as: :json
    assert_response :success
    assert_equal "account_wide", response.parsed_body.dig("workspace", "access_mode")

    store_workspace = create_workspace(headers, key: "contract-store")
    post "/agent_api/v1/workspaces/#{store_workspace.fetch("public_id")}/store_entries",
      params: contract("store_entries.json").fetch("valid_create_request"),
      headers: headers.merge("Idempotency-Key" => "contract-store-entry"),
      as: :json
    assert_response :created
    entry = response.parsed_body.fetch("store_entry")
    assert_wire_shape contract("store_entries.json").fetch("valid_fixture"),
      response.parsed_body

    update_entry = deep_copy(contract("store_entries.json").fetch("valid_update_request"))
    update_entry.dig("store_entry")["lock_version"] = entry.fetch("lock_version")
    patch "/agent_api/v1/workspaces/#{store_workspace.fetch("public_id")}/store_entries/#{entry.fetch("public_id")}",
      params: update_entry, headers: headers, as: :json
    assert_response :success
    entry = response.parsed_body.fetch("store_entry")
    assert_equal({ "pinned" => true }, entry.fetch("value"))

    store_contract = contract("store_entries.json")
    delete_params = store_contract.fetch("valid_delete_params")
      .merge("lock_version" => entry.fetch("lock_version"))
    delete "/agent_api/v1/workspaces/#{store_workspace.fetch("public_id")}/store_entries/#{entry.fetch("public_id")}",
      params: delete_params, headers: headers, as: :json
    delete_fixture = store_contract.fetch("valid_delete_fixture")
    assert_equal delete_fixture.fetch("status"), response.status
    assert_nil delete_fixture.fetch("body")
    assert_empty response.body

    lifecycle_workspace = create_workspace(headers, key: "contract-lifecycle")
    lifecycle_request = deep_copy(contract("workspaces.json").fetch("valid_lifecycle_request"))
    lifecycle_request.dig("command")["lock_version"] = lifecycle_workspace.fetch("lock_version")
    post "/agent_api/v1/workspaces/#{lifecycle_workspace.fetch("public_id")}/archival",
      params: lifecycle_request, headers: headers, as: :json
    assert_response :success

    transfer_workspace = create_workspace(headers, key: "contract-transfer")
    transfer_request = deep_copy(contract("workspaces.json").fetch("valid_transfer_request"))
    transfer_request.dig("ownership_transfer")["target_user_public_id"] = users(:member).public_id
    transfer_request.dig("ownership_transfer")["lock_version"] =
      transfer_workspace.fetch("lock_version")
    post "/agent_api/v1/workspaces/#{transfer_workspace.fetch("public_id")}/ownership_transfer",
      params: transfer_request, headers: headers, as: :json
    assert_response :success
    assert_equal users(:member).public_id,
      response.parsed_body.dig("workspace", "owner", "public_id")

    delete_workspace = create_workspace(headers, key: "contract-delete")
    delete_params = contract("workspaces.json").fetch("valid_delete_params")
      .merge("lock_version" => delete_workspace.fetch("lock_version"))
    delete "/agent_api/v1/workspaces/#{delete_workspace.fetch("public_id")}",
      params: delete_params, headers: headers, as: :json
    assert_response :success
    assert_equal "deleting", response.parsed_body.dig("workspace", "state")
  end

  # THE OVERRIDE OPT-IN: the pack's request lands on the real door against a real provider, and the
  # Full projection's key set is the fixture's — the override entry carries the three keys the docs
  # name.
  test "the tool provider overrides request passes through its real door onto the Full projection" do
    credential = create_access_token_fixture(user: users(:owner), name: "Contract overrides")
    headers = bearer(credential.secret)
    workspace = create_workspace(headers, key: "contract-overrides")
    provider = connect_provider(identifier: "contract-mem", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))
    pack = contract("workspaces.json")
    assert_equal ["nexus.memory"], pack.fetch("overridable_namespaces")

    request = deep_copy(pack.fetch("valid_tool_provider_overrides_request"))
    assert_equal pack.fetch("overridable_namespaces"),
      request.dig("tool_provider_overrides", "overrides").keys, "the fixture names an overridable namespace"
    request.dig("tool_provider_overrides", "overrides")["nexus.memory"] = provider.public_id
    request.dig("tool_provider_overrides")["lock_version"] = workspace.fetch("lock_version")
    put "/agent_api/v1/workspaces/#{workspace.fetch("public_id")}/tool_provider_overrides",
      params: request, headers: headers, as: :json
    assert_response :success

    fixture = pack.fetch("valid_full_fixture").fetch("workspace")
    body = response.parsed_body.fetch("workspace")
    assert_equal fixture.keys.sort, body.keys.sort
    assert_equal %w[assignment_scope display_name provider_public_id],
      body.dig("tool_provider_overrides", "nexus.memory").keys.sort
    assert_equal provider.public_id, body.dig("tool_provider_overrides", "nexus.memory", "provider_public_id")

    request.dig("tool_provider_overrides")["lock_version"] = body.fetch("lock_version")
    request.dig("tool_provider_overrides")["overrides"] = { "nexus.graph" => provider.public_id }
    put "/agent_api/v1/workspaces/#{workspace.fetch("public_id")}/tool_provider_overrides",
      params: request, headers: headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "reserved_namespace", response.parsed_body.dig("error", "code")
    assert_equal pack.dig("error_statuses", "reserved_namespace"), response.status
  end

  # ONE PRESENTER, THREE DOORS: the pack's create request lands on the conversation and profile
  # routes and answers the same fixture.
  test "the conversation and profile store doors produce the one StoreEntry fixture" do
    credential = create_access_token_fixture(user: users(:owner), name: "Contract store doors")
    headers = bearer(credential.secret)
    workspace = create_workspace(headers, key: "contract-store-doors")
    conversation = Conversation.create!(
      workspace: Workspace.find_by!(public_id: workspace.fetch("public_id")),
      creating_user: users(:owner)
    )
    create_request = contract("store_entries.json").fetch("valid_create_request")
    valid_fixture = contract("store_entries.json").fetch("valid_fixture")

    post agent_api_v1_workspace_conversation_store_entries_path(
      workspace.fetch("public_id"), conversation.public_id
    ), params: create_request,
      headers: headers.merge("Idempotency-Key" => "contract-store-conversation"), as: :json
    assert_response :created
    assert_wire_shape valid_fixture, response.parsed_body

    post agent_api_v1_profile_store_entries_path, params: create_request,
      headers: headers.merge("Idempotency-Key" => "contract-store-profile"), as: :json
    assert_response :created
    assert_wire_shape valid_fixture, response.parsed_body

    # The profile door keeps no receipt: the same key again is the pack's
    # own error fixture, never a replay.
    post agent_api_v1_profile_store_entries_path, params: create_request,
      headers: headers.merge("Idempotency-Key" => "contract-store-profile"), as: :json
    assert_contract_error "store_entries.json"
    assert_equal "key_taken", response.parsed_body.dig("error", "code")
  end

  test "Workspace and StoreEntry list producers match the pack" do
    workspaces(:shared).update!(access_mode: :private)
    credential = create_access_token_fixture(user: users(:member), name: "Contract lists")
    headers = bearer(credential.secret)
    workspace = create_workspace(headers, key: "contract-workspace-list")

    get agent_api_v1_workspaces_path, headers: headers
    assert_response :success
    assert_list_fixture(
      contract("workspaces.json").fetch("valid_list_fixture"),
      response.parsed_body,
      collection: "workspaces"
    )

    post agent_api_v1_workspace_store_entries_path(workspace.fetch("public_id")),
      params: contract("store_entries.json").fetch("valid_create_request"),
      headers: headers.merge("Idempotency-Key" => "contract-store-entry-list"),
      as: :json
    assert_response :created

    get agent_api_v1_workspace_store_entries_path(workspace.fetch("public_id")),
      headers: headers
    assert_response :success
    assert_list_fixture(
      contract("store_entries.json").fetch("valid_list_fixture"),
      response.parsed_body,
      collection: "store_entries"
    )
  end

  test "Workspace unknown request fixtures are rejected by their real parsers" do
    credential = create_access_token_fixture(user: users(:owner), name: "Contract rejection")
    headers = bearer(credential.secret)
    workspaces = contract("workspaces.json")

    get agent_api_v1_workspaces_path,
      params: workspaces.fetch("unknown_state_filter_request"),
      headers: headers
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")

    workspace = create_workspace(headers, key: "contract-rejection")
    request = deep_copy(workspaces.fetch("unknown_access_mode_request"))
    request.dig("access_mode")["lock_version"] = workspace.fetch("lock_version")
    put "/agent_api/v1/workspaces/#{workspace.fetch("public_id")}/access_mode",
      params: request,
      headers: headers,
      as: :json
    assert_response :unprocessable_entity
    assert_equal "invalid_access_mode", response.parsed_body.dig("error", "code")
  end

  # THE TWO PLANES' RENDERED FIXTURES AGAINST THE LIVE WIRE (audit
  # wire-18, wire-21): a conversation the door creates carries exactly the
  # pack's Full keys (`runner` and `context` among them, both null until a
  # binding or a settled turn fills them); a loop the door creates and its
  # seed's single-task read carry no key the presenter-rendered fixtures
  # lack, and `task_progress` is the presenter's bucket per status.
  test "the conversation and loop documents the doors create carry the pack's rendered keys" do
    # The member of the account whose dev lane the helper enables, so the
    # seed's `dev/mock-text` resolves at the create door.
    DevModelLane.ensure_enabled!(accounts(:cybros))
    credential = create_access_token_fixture(user: users(:member), name: "Contract planes")
    headers = bearer(credential.secret)
    workspace = create_workspace(headers, key: "contract-planes")

    post agent_api_v1_workspace_conversations_path(workspace.fetch("public_id")),
      params: { conversation: { title: "Planning" } },
      headers: headers.merge("Idempotency-Key" => "contract-conversation-full"), as: :json
    assert_response :created, response.body
    conversation_fixture = contract("conversations.json").dig("valid_fixture", "conversation")
    live = response.parsed_body.fetch("conversation")
    assert_equal conversation_fixture.keys.sort, live.keys.sort, "the Full projection, key for key"
    assert_nil live.fetch("default_runner"), "the binding is always rendered, nil when unbound"
    assert_nil live.fetch("context"), "provider truth is rendered null until a turn settled"
    usage = live.fetch("usage_summary")
    assert_equal contract("conversations.json").fetch("usage_summary_projection_required").sort,
      usage.keys.sort, "an unused conversation renders the required cumulative counters"
    assert_equal [0, 0, "0.0", true],
      usage.values_at("request_count", "total_tokens", "cost_amount", "cost_complete")
    assert usage.key?("cost_unit"), "the account's unit is present even before one is configured"

    loops = contract("runs.json")
    post agent_api_v1_workspace_runs_path(workspace.fetch("public_id")),
      params: { run: { approval_mode: "bypass",
                              steps: [{ model: { key: "seed", model: { model: "dev/mock-text" }, prompt: "s" } }] } },
      headers: headers.merge("Idempotency-Key" => "contract-loop-full"), as: :json
    assert_response :created
    loop_fixture = loops.dig("valid_request_run_fixture", "run")
    live_loop = response.parsed_body.fetch("run")
    assert_empty live_loop.keys - loop_fixture.keys
    assert_equal loops.fetch("task_progress_projection").sort, live_loop.fetch("task_progress").keys.sort,
      "one bucket per public status, plus the total"

    get "/agent_api/v1/workspaces/#{workspace.fetch("public_id")}/runs/#{live_loop.fetch("public_id")}/tasks/seed",
      headers: headers
    assert_response :success
    assert_empty response.parsed_body.fetch("task").keys - loops.dig("valid_task_detail_fixture", "task").keys,
      "a round's read renders no key the rendered fixture lacks"

    # THE EXTENDED ENVELOPES (audit wire-27) on their real doors: the
    # members beside `code` and `message` are exactly the ones errors.json
    # publishes.
    extended = contract("errors.json").fetch("extended_envelopes")
    loop_path = "/agent_api/v1/workspaces/#{workspace.fetch("public_id")}/runs/#{live_loop.fetch("public_id")}"
    post "#{loop_path}/tasks", params: { steps: [{ ask: { key: "later", prompt: "?" } }], expected_revision: 99 },
      headers: headers, as: :json
    assert_extended_envelope extended, "stale_revision", loops.dig("error_statuses", "stale_revision")
    post "#{loop_path}/tasks", params: { steps: [{ ask: { key: "later", prompt: "?" } }], tasks: [] },
      headers: headers, as: :json
    assert_extended_envelope extended, "edge_authoring_refused", loops.dig("error_statuses", "edge_authoring_refused")
    post "#{loop_path}/tasks",
      params: { steps: [{ model: { key: "more", model: { model: "dev/mock-text" }, prompt: "m", depends_on: ["x"] } }] },
      headers: headers, as: :json
    assert_extended_envelope extended, "invalid_steps", loops.dig("error_statuses", "invalid_steps")
  end

  # THE MODEL PLANE'S RENDERED ROWS AGAINST THE ROUTES (audit wire-22): the
  # listing's rows, their capabilities and pricing blocks, and the lane rows
  # carry exactly the projections the two presenters rendered into the pack.
  test "the models and model_providers listings carry the pack's projections" do
    DevModelLane.ensure_enabled!(accounts(:cybros))
    credential = create_access_token_fixture(user: users(:member), name: "Contract models")
    headers = bearer(credential.secret)
    models = contract("models.json")

    get agent_api_v1_models_path, headers: headers
    assert_response :success
    rows = response.parsed_body.fetch(models.fetch("listing_envelope").sole)
    assert_not_empty rows
    rows.each do |row|
      assert_equal models.fetch("row_projection"), row.keys, row.fetch("ref")
      assert row.fetch("available") && row.fetch("visible"), row.fetch("ref")
      assert_equal models.fetch("capabilities_projection"), row.fetch("capabilities").keys, row.fetch("ref")
      assert_empty row.fetch("pricing").keys - models.fetch("pricing_projection"), row.fetch("ref")
      assert_includes models.fetch("pricing_states"), row.dig("pricing", "state"), row.fetch("ref")
      assert_includes models.fetch("workloads"), row.fetch("workload")
      next if row.fetch("unavailable_reason").nil?

      assert_includes models.fetch("unavailable_reasons"), row.fetch("unavailable_reason"), row.fetch("ref")
    end

    get agent_api_v1_model_providers_path, headers: headers
    assert_response :success
    lanes = response.parsed_body.fetch(models.fetch("providers_envelope").sole)
    assert_not_empty lanes
    lanes.each do |lane|
      assert_equal models.fetch("provider_projection"), lane.keys, lane.fetch("id")
      assert_includes models.fetch("credentials"), lane.fetch("credentials"), lane.fetch("id")
    end
  end

  # THE TWO FILTER REFUSALS the pack names (audit wire-23, wire-26): a
  # direction and a discovery kind outside their closed words are the
  # family's 400, from the real parsers.
  test "unknown order and discovery-kind filters are rejected by their real parsers" do
    credential = create_access_token_fixture(user: users(:owner), name: "Contract filters")
    headers = bearer(credential.secret)

    get agent_api_v1_workspaces_path,
      params: contract("workspaces.json").fetch("unknown_order_request"), headers: headers
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    get agent_api_v1_workspaces_path,
      params: contract("workspaces.json").fetch("valid_order_request"), headers: headers
    assert_response :success

    executors = contract("task_executors.json")
    get agent_api_v1_executors_path,
      params: executors.fetch("unknown_discovery_kind_filter_request"), headers: headers
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    get agent_api_v1_executors_path,
      params: executors.fetch("valid_discovery_kind_filter_request"), headers: headers
    assert_response :success
    assert_equal executors.fetch("discovery_envelope"), response.parsed_body.keys
  end

  private

    def assert_extended_envelope(extended, code, status)
      assert_equal status, response.status, response.body
      error = response.parsed_body.fetch("error")
      assert_equal code, error.fetch("code")
      assert_equal (%w[code message] + extended.fetch(code)).sort, error.keys.sort, code
    end

    def contract(name)
      Nexus::Contract.pack.fetch(name)
    end

    def bearer(secret)
      { "Authorization" => "Bearer #{secret}" }
    end

    def create_workspace(headers, key:)
      post agent_api_v1_workspaces_path,
        params: contract("workspaces.json").fetch("valid_create_request"),
        headers: headers.merge("Idempotency-Key" => key),
        as: :json
      assert_response :created
      fixture = contract("workspaces.json").fetch("valid_full_fixture")
      assert_wire_shape fixture, response.parsed_body
      assert_equal fixture.dig("workspace", "creator", "kind"),
        response.parsed_body.dig("workspace", "creator", "kind")
      response.parsed_body.fetch("workspace")
    end

    def connected_agent_pair
      member = accounts(:cybros).users.create!(
        kind: :agent,
        role: :member,
        steward: users(:owner),
        display_name: "Fixture agent",
        agent_identifier: "contract-token-agent"
      )
      mint = DeviceAuthorizations::Issue.call(
        account: accounts(:cybros),
        agent_identifier: member.agent_identifier,
        agent_display_name: member.display_name,
        requested_executor_display_name: "Contract token executor"
      )
      mint.authorization.update!(
        status: :connected,
        user: member,
        connected_by: users(:owner),
        connected_by_authority_generation: users(:owner).authority_generation,
        user_authority_generation: member.authority_generation
      )
      [mint.authorization, mint.device_code]
    end

    # The combined request is the agent request plus the runner pair, over
    # the wire; the human connects it on the ONE agent page.
    def connected_combined_code
      oauth = contract("oauth.json")
      post oauth_device_authorization_path,
        params: oauth.fetch("agent_authorization_request").merge(
          "registration_identifier" => "fixture-rho", "runner_display_name" => "Fixture rho"
        ),
        as: :json
      assert_response :success

      code = response.parsed_body.fetch("device_code")
      authorization = DeviceAuthorization.find_by_device_code(code)
      assert_predicate authorization, :combined_connection?
      assert_equal :connected,
        DeviceAuthorizations::Connect.call(authorization: authorization, connector: users(:owner)).outcome
      code
    end

    def connected_runner_code
      oauth = contract("oauth.json")
      post oauth_device_authorization_path,
        params: oauth.fetch("runner_authorization_request"),
        as: :json
      assert_response :success

      code = response.parsed_body.fetch("device_code")
      authorization = DeviceAuthorization.find_by_device_code(code)
      DeviceAuthorizations::Connect.call(
        authorization: authorization,
        connector: users(:owner),
        expected_live_runner: DeviceAuthorizations::Connect::ABSENT_LIVE_RUNNER
      )
      code
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def assert_list_fixture(fixture, actual, collection:)
      assert_wire_shape fixture, actual

      normalized = deep_copy(actual)
      fixture_item = fixture.fetch(collection).fetch(0)
      normalized_item = normalized.fetch(collection).fetch(0)
      %w[public_id created_at updated_at].each do |field|
        normalized_item[field] = fixture_item.fetch(field)
      end

      assert_equal fixture, normalized
    end

    def assert_contract_error(name)
      fixture_key = name == "errors.json" ? "valid_fixture" : "valid_error_fixture"
      fixture = contract(name).fetch(fixture_key)

      assert_equal fixture.fetch("status"), response.status
      assert_wire_shape fixture.fetch("body"), response.parsed_body
      expected_error = fixture.dig("body", "error")
      actual_error = response.parsed_body.fetch("error")
      if expected_error.is_a?(Hash)
        assert_equal expected_error.fetch("code"), actual_error.fetch("code")
      else
        assert_equal expected_error, actual_error
      end
    end

    def assert_wire_shape(expected, actual, path = "$")
      case expected
      when Hash
        assert_kind_of Hash, actual, path
        assert_equal expected.keys.sort, actual.keys.sort, path
        expected.each do |key, value|
          assert_wire_shape(value, actual.fetch(key), "#{path}/#{key}")
        end
      when Array
        assert_kind_of Array, actual, path
        assert_equal expected.length, actual.length, path
        expected.each_with_index do |value, index|
          assert_wire_shape(value, actual.fetch(index), "#{path}/#{index}")
        end
      when NilClass
        assert_nil actual, path
      else
        assert_instance_of expected.class, actual, path
      end
    end
end
