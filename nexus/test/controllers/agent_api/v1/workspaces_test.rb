require "test_helper"

# The Workspace member-plane family (2026-07-30 plan): every frozen mapping
# row, both 404/403 postures, the per-principal create allowlists, and the
# receipt replay boundary, driven through the public routes.
class AgentAPI::V1::WorkspacesTest < ActionDispatch::IntegrationTest
  include AgentMembershipTestHelper

  setup do
    @curator = create_access_token_fixture(user: users(:curator), name: "Curator")
    @member = create_access_token_fixture(user: users(:member), name: "Member")
    # An Agent's member credential is OAuth-only, so it comes from the real
    # connection ceremony rather than a fixture shortcut.
    @agent_secret = connect_agent_session(
      steward: users(:owner), agent_identifier: users(:agent).agent_identifier
    ).access_secret
  end

  test "the default list is live-scoped, keyset-paginated, and Basic-projected" do
    workspaces(:dedicated).update_columns(state: "archived", archived_at: Time.current)

    get agent_api_v1_workspaces_path, headers: bearer(@curator), params: { limit: 1 }

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["workspaces"].length
    first = body["workspaces"].first
    assert_equal %w[access_mode archived_at created_at dedicated lock_version name public_id state updated_at],
      first.keys.sort
    assert_not first.key?("metadata"), "lists are Basic"

    next_after = body.dig("pagination", "next_after")
    assert next_after.present?
    get agent_api_v1_workspaces_path, headers: bearer(@curator), params: { limit: 50, after: next_after }
    assert_response :success
    rest = response.parsed_body
    assert_nil rest.dig("pagination", "next_after")
    all_ids = body["workspaces"].map { |w| w["public_id"] } + rest["workspaces"].map { |w| w["public_id"] }
    assert_equal [workspaces(:personal), workspaces(:shared)].map(&:public_id).sort, all_ids.sort
  end

  test "the archived filter is the recycle bin and unknown state values are 400" do
    workspaces(:personal).update_columns(state: "archived", archived_at: Time.current)

    get agent_api_v1_workspaces_path, headers: bearer(@curator), params: { state: "archived" }
    assert_response :success
    assert_equal [workspaces(:personal).public_id],
      response.parsed_body["workspaces"].map { |w| w["public_id"] }

    get agent_api_v1_workspaces_path, headers: bearer(@curator), params: { state: "limbo" }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
  end

  test "a garbage cursor is 400 and a limit above the maximum clamps to 100" do
    get agent_api_v1_workspaces_path, headers: bearer(@curator), params: { after: "not-a-cursor" }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")

    [0, "not-an-integer"].each do |limit|
      get agent_api_v1_workspaces_path, headers: bearer(@curator), params: { limit: limit }
      assert_response :bad_request
      assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    end

    existing_count = Workspace.data_accessible_to(users(:curator)).live.count
    (101 - existing_count).times do |index|
      Workspace.create!(
        account: users(:curator).account,
        creator: users(:curator),
        owner: users(:curator),
        name: "Clamp #{index}",
        access_mode: "private"
      )
    end

    get agent_api_v1_workspaces_path, headers: bearer(@curator), params: { limit: 101 }
    assert_response :success
    assert_equal 100, response.parsed_body.fetch("workspaces").length
    assert response.parsed_body.dig("pagination", "next_after").present?
  end

  test "dedication visibility resolves server-side by principal and selector" do
    other_agent = create_agent_member(
      steward: users(:owner), agent_identifier: "other-agent-dedication"
    )
    other_dedicated = Workspace.create!(
      account: users(:owner).account,
      creator: other_agent,
      owner: users(:owner),
      name: "Other Agent Home",
      access_mode: "private",
      agent_identifier: other_agent.agent_identifier
    )
    shared_id = workspaces(:shared).public_id
    dedicated_id = workspaces(:dedicated).public_id

    [nil, "false"].each do |selector|
      params = selector ? { dedicated_to_current_agent: selector } : {}
      get agent_api_v1_workspaces_path, headers: bearer_secret(@agent_secret), params: params
      assert_response :success
      assert_equal [shared_id], response.parsed_body["workspaces"].map { |workspace| workspace["public_id"] },
        "Agents see only undedicated Workspaces by default"
    end

    get agent_api_v1_workspaces_path, headers: bearer_secret(@agent_secret),
      params: { dedicated_to_current_agent: "true" }
    assert_response :success
    assert_equal [dedicated_id],
      response.parsed_body["workspaces"].map { |w| w["public_id"] }

    owner = create_access_token_fixture(user: users(:owner), name: "Owner dedication list")
    [nil, "false"].each do |selector|
      params = selector ? { dedicated_to_current_agent: selector } : {}
      get agent_api_v1_workspaces_path, headers: bearer(owner), params: params
      assert_response :success
      assert_equal [shared_id, dedicated_id, other_dedicated.public_id].sort,
        response.parsed_body["workspaces"].map { |workspace| workspace["public_id"] }.sort,
        "Humans keep their ordinary accessible scope"
    end

    get agent_api_v1_workspaces_path, headers: bearer(owner), params: { dedicated_to_current_agent: "true" }
    assert_response :success
    assert_empty response.parsed_body["workspaces"]

    get agent_api_v1_workspaces_path, headers: bearer_secret(@agent_secret),
      params: { dedicated_to_current_agent: "yes" }
    assert_response :bad_request
  end

  test "show is Full for a reader and conceals no-access and tombstones as 404" do
    get agent_api_v1_workspace_path(workspaces(:dedicated).public_id), headers: bearer_secret(@agent_secret)
    assert_response :success
    body = response.parsed_body["workspace"]
    assert_equal true, body["dedicated"]
    assert_not body.key?("agent_identifier"), "the exact identifier never renders"
    assert_equal users(:owner).public_id, body.dig("owner", "public_id")
    assert_equal users(:agent).public_id, body.dig("creator", "public_id")
    assert_equal "agent", body.dig("creator", "kind")

    get agent_api_v1_workspace_path(workspaces(:personal).public_id), headers: bearer(@member)
    assert_response :not_found

    workspaces(:shared).update_columns(state: "deleting", deleted_at: Time.current)
    get agent_api_v1_workspace_path(workspaces(:shared).public_id), headers: bearer(@member)
    assert_response :not_found
  end

  test "a Human creates with idempotent replay and digest mismatch" do
    key = SecureRandom.uuid
    payload = { workspace: { name: "Fresh", access_mode: "account_wide" } }

    assert_difference -> { Workspace.count }, +1 do
      post agent_api_v1_workspaces_path, headers: bearer(@member).merge("Idempotency-Key" => key),
        params: payload, as: :json
    end
    assert_response :created
    created = response.parsed_body["workspace"]
    assert_equal "account_wide", created["access_mode"]
    assert_equal users(:member).public_id, created.dig("owner", "public_id")

    assert_no_difference -> { Workspace.count } do
      post agent_api_v1_workspaces_path, headers: bearer(@member).merge("Idempotency-Key" => key),
        params: payload, as: :json
    end
    assert_response :created
    assert_equal created["public_id"], response.parsed_body.dig("workspace", "public_id")

    post agent_api_v1_workspaces_path, headers: bearer(@member).merge("Idempotency-Key" => key),
      params: { workspace: { name: "Different" } }, as: :json
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
  end

  test "idempotent create digests the persisted name representation" do
    key = SecureRandom.uuid

    assert_difference -> { Workspace.count }, +1 do
      post agent_api_v1_workspaces_path,
        headers: bearer(@member).merge("Idempotency-Key" => key),
        params: { workspace: { name: 123 } },
        as: :json
    end
    assert_response :created
    created = response.parsed_body.fetch("workspace")
    assert_equal "123", created.fetch("name")

    assert_no_difference -> { Workspace.count } do
      post agent_api_v1_workspaces_path,
        headers: bearer(@member).merge("Idempotency-Key" => key),
        params: { workspace: { name: "123" } },
        as: :json
    end
    assert_response :created
    assert_equal created.fetch("public_id"), response.parsed_body.dig("workspace", "public_id")
  end

  test "creation requires an Idempotency-Key and bounds it" do
    post agent_api_v1_workspaces_path, headers: bearer(@member),
      params: { workspace: { name: "No Key" } }, as: :json
    assert_response :bad_request
    assert_equal "idempotency_key_required", response.parsed_body.dig("error", "code")

    post agent_api_v1_workspaces_path,
      headers: bearer(@member).merge("Idempotency-Key" => "k" * 256),
      params: { workspace: { name: "Long Key" } }, as: :json
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
  end

  test "an Agent create is always private and dedicated and ignores foreign fields" do
    secret = connect_agent_session(
      steward: users(:member), agent_identifier: "api-create-agent"
    ).access_secret

    post agent_api_v1_workspaces_path,
      headers: bearer_secret(secret).merge("Idempotency-Key" => SecureRandom.uuid),
      params: {
        workspace: {
          name: "Mine",
          access_mode: "account_wide",
          dedicated: false,
          agent_identifier: "foreign-agent",
        },
      },
      as: :json

    assert_response :created
    body = response.parsed_body["workspace"]
    assert_equal "private", body["access_mode"], "an Agent's access_mode field is outside its allowlist"
    assert_equal true, body["dedicated"]
    assert_equal users(:member).public_id, body.dig("owner", "public_id")
    assert_equal "api-create-agent", Workspace.find_by!(name: "Mine").agent_identifier
  end

  test "a Human-supplied dedicated flag is ignored like any unknown field" do
    post agent_api_v1_workspaces_path,
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { workspace: { name: "Not Dedicated", dedicated: true, agent_identifier: "sneak" } },
      as: :json

    assert_response :created
    assert_equal false, response.parsed_body.dig("workspace", "dedicated")
    assert_nil Workspace.find_by!(name: "Not Dedicated").agent_identifier
  end

  test "oversize metadata is 413 and other validation failures are 422" do
    post agent_api_v1_workspaces_path,
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { workspace: { name: "Big", metadata: { "k" => "a" * 3000 } } }, as: :json
    assert_response :content_too_large
    assert_equal "content_too_large", response.parsed_body.dig("error", "code")

    post agent_api_v1_workspaces_path,
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { workspace: { name: "" } }, as: :json
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
  end

  test "create rejects present non-object metadata while unknown fields remain ignored" do
    ["text", [1, 2]].each do |metadata|
      assert_no_difference -> { Workspace.count } do
        post agent_api_v1_workspaces_path,
          headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
          params: { workspace: { name: "Invalid metadata", metadata: metadata } }, as: :json
      end

      assert_response :unprocessable_entity
      assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    end

    post agent_api_v1_workspaces_path,
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: {
        workspace: {
          name: "Known fields only",
          metadata: { "valid" => true },
          unknown: { "ignored" => true },
        },
      },
      as: :json

    assert_response :created
    workspace = Workspace.find_by!(name: "Known fields only")
    assert_equal({ "valid" => true }, workspace.metadata)
  end

  test "PATCH renames under a required lock_version with stale and empty-change mappings" do
    workspace = workspaces(:personal)

    patch agent_api_v1_workspace_path(workspace.public_id), headers: bearer(@curator),
      params: { workspace: { name: "Renamed", lock_version: workspace.lock_version } }, as: :json
    assert_response :success
    assert_equal "Renamed", workspace.reload.name

    patch agent_api_v1_workspace_path(workspace.public_id), headers: bearer(@curator),
      params: { workspace: { name: "Again" } }, as: :json
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")

    patch agent_api_v1_workspace_path(workspace.public_id), headers: bearer(@curator),
      params: { workspace: { name: "Stale", lock_version: 0 } }, as: :json
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")

    patch agent_api_v1_workspace_path(workspace.public_id), headers: bearer(@curator),
      params: { workspace: { lock_version: workspace.reload.lock_version } }, as: :json
    assert_response :unprocessable_entity

    patch agent_api_v1_workspace_path(workspace.public_id), headers: bearer(@curator),
      params: { workspace: { name: "Bad", lock_version: "abc" } }, as: :json
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
  end

  test "PATCH rejects present non-object metadata while unknown fields remain ignored" do
    workspace = workspaces(:personal)

    ["text", [1, 2]].each do |metadata|
      patch agent_api_v1_workspace_path(workspace.public_id), headers: bearer(@curator),
        params: {
          workspace: {
            name: "Must not apply",
            metadata: metadata,
            lock_version: workspace.reload.lock_version,
          },
        },
        as: :json

      assert_response :unprocessable_entity
      assert_equal "validation_failed", response.parsed_body.dig("error", "code")
      assert_equal({}, workspace.reload.metadata)
      assert_equal "Curator Private", workspace.name
    end

    patch agent_api_v1_workspace_path(workspace.public_id), headers: bearer(@curator),
      params: {
        workspace: {
          metadata: { "valid" => true },
          unknown: "ignored",
          lock_version: workspace.reload.lock_version,
        },
      },
      as: :json

    assert_response :success
    assert_equal({ "valid" => true }, workspace.reload.metadata)
  end

  test "a reader without management authority earns an honest 403" do
    patch agent_api_v1_workspace_path(workspaces(:shared).public_id), headers: bearer(@member),
      params: { workspace: { name: "Taken", lock_version: workspaces(:shared).lock_version } },
      as: :json
    assert_response :forbidden
    assert_equal "not_workspace_owner", response.parsed_body.dig("error", "code")

    patch agent_api_v1_workspace_path(workspaces(:dedicated).public_id),
      headers: bearer_secret(@agent_secret),
      params: { workspace: { name: "Self", lock_version: workspaces(:dedicated).lock_version } },
      as: :json
    assert_response :forbidden
  end

  test "access mode changes cut immediately and validate the closed vocabulary" do
    shared = workspaces(:shared)
    owner = create_access_token_fixture(user: users(:owner), name: "Owner")

    put agent_api_v1_workspace_access_mode_path(shared.public_id), headers: bearer(owner),
      params: { access_mode: { access_mode: "private", lock_version: shared.lock_version } },
      as: :json
    assert_response :success
    assert_equal "private", shared.reload.access_mode

    get agent_api_v1_workspace_path(shared.public_id), headers: bearer(@member)
    assert_response :not_found

    put agent_api_v1_workspace_access_mode_path(shared.public_id), headers: bearer(owner),
      params: { access_mode: { access_mode: "public", lock_version: shared.reload.lock_version } },
      as: :json
    assert_response :unprocessable_entity
  end

  test "ownership transfer moves the owner and rejects ineligible targets as 422" do
    workspace = workspaces(:personal)

    post agent_api_v1_workspace_ownership_transfer_path(workspace.public_id),
      headers: bearer(@curator),
      params: { ownership_transfer: {
        target_user_public_id: users(:member).public_id, lock_version: workspace.lock_version,
      } }, as: :json
    assert_response :success
    assert_equal users(:member), workspace.reload.owner

    [users(:agent).public_id, users(:member).public_id, SecureRandom.uuid_v7].each do |target|
      post agent_api_v1_workspace_ownership_transfer_path(workspace.public_id),
        headers: bearer(@member),
        params: { ownership_transfer: {
          target_user_public_id: target, lock_version: workspace.reload.lock_version,
        } }, as: :json
      assert_response :unprocessable_entity, target
      assert_equal "target_not_eligible", response.parsed_body.dig("error", "code")
    end
  end

  test "the lifecycle loop runs through the public commands" do
    workspace = workspaces(:personal)

    post agent_api_v1_workspace_archival_path(workspace.public_id), headers: bearer(@curator),
      params: { command: { lock_version: workspace.lock_version } }, as: :json
    assert_response :success
    assert_equal "archiving", response.parsed_body.dig("workspace", "state"),
      "the response reports the acceptance state"
    assert_equal "archived", workspace.reload.state,
      "inline post-commit completion converged the trivial transition"

    post agent_api_v1_workspace_restoration_path(workspace.public_id), headers: bearer(@curator),
      params: { command: { lock_version: workspace.lock_version } }, as: :json
    assert_response :success
    assert_equal "active", workspace.reload.state

    delete agent_api_v1_workspace_path(workspace.public_id), headers: bearer(@curator),
      params: { lock_version: workspace.lock_version }
    assert_response :success
    assert_equal "deleting", response.parsed_body.dig("workspace", "state")
    assert_equal "deleted", workspace.reload.state

    get agent_api_v1_workspace_path(workspace.public_id), headers: bearer(@curator)
    assert_response :not_found
  end

  test "repeat lifecycle commands map the no-op and in-progress rows" do
    workspace = workspaces(:personal)
    workspace.update_columns(state: "archived", archived_at: Time.current)

    post agent_api_v1_workspace_archival_path(workspace.public_id), headers: bearer(@curator),
      params: { command: { lock_version: workspace.lock_version } }, as: :json
    assert_response :success
    assert_equal "archived", response.parsed_body.dig("workspace", "state")

    workspace.update_columns(state: "archiving")
    post agent_api_v1_workspace_restoration_path(workspace.public_id), headers: bearer(@curator),
      params: { command: { lock_version: workspace.lock_version } }, as: :json
    assert_response :conflict
    assert_equal "transition_in_progress", response.parsed_body.dig("error", "code")

    post agent_api_v1_workspace_ownership_transfer_path(workspace.public_id),
      headers: bearer(@curator),
      params: { ownership_transfer: {
        target_user_public_id: users(:member).public_id, lock_version: workspace.lock_version,
      } }, as: :json
    assert_response :conflict
    assert_equal "workspace_not_active", response.parsed_body.dig("error", "code")
  end

  test "a DELETE without its query lock_version is 400" do
    delete agent_api_v1_workspace_path(workspaces(:personal).public_id), headers: bearer(@curator)

    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end

  test "replay through lost access conceals the stored response" do
    key = SecureRandom.uuid
    post agent_api_v1_workspaces_path, headers: bearer(@member).merge("Idempotency-Key" => key),
      params: { workspace: { name: "Mine" } }, as: :json
    assert_response :created
    created_id = response.parsed_body.dig("workspace", "public_id")

    workspace = Workspace.find_by!(public_id: created_id)
    result = ::Workspaces::TransferOwnership.call(
      workspace: workspace, by: users(:member), to: users(:owner),
      lock_version: workspace.lock_version
    )
    assert_equal :transferred, result.outcome

    post agent_api_v1_workspaces_path, headers: bearer(@member).merge("Idempotency-Key" => key),
      params: { workspace: { name: "Mine" } }, as: :json
    assert_response :not_found
  end

  test "exponent-form metadata numbers are the frozen 422, never a 500" do
    post agent_api_v1_workspaces_path,
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { workspace: { name: "Exponent", metadata: { "v" => 1e308 } } }, as: :json

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
  end

  test "uncarryable metadata text is a descriptive validation 422" do
    post agent_api_v1_workspaces_path,
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { workspace: { name: "NUL", metadata: { "v" => "a\u0000b" } } }, as: :json

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), "U+0000"
  end

  test "explicit JSON null is rejected where the shape says non-null" do
    post agent_api_v1_workspaces_path,
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { workspace: { name: "Null Meta", metadata: nil } }, as: :json
    assert_response :unprocessable_entity

    post agent_api_v1_workspaces_path,
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { workspace: { name: "Null Mode", access_mode: nil } }, as: :json
    assert_response :unprocessable_entity

    patch agent_api_v1_workspace_path(workspaces(:personal).public_id), headers: bearer(@curator),
      params: { workspace: { metadata: nil, lock_version: workspaces(:personal).lock_version } },
      as: :json
    assert_response :unprocessable_entity
  end

  test "an unsupported access mode is the typed invalid_access_mode on both producers" do
    owner = create_access_token_fixture(user: users(:owner), name: "Owner")
    put agent_api_v1_workspace_access_mode_path(workspaces(:shared).public_id),
      headers: bearer(owner),
      params: { access_mode: { access_mode: "public", lock_version: workspaces(:shared).lock_version } },
      as: :json
    assert_response :unprocessable_entity
    assert_equal "invalid_access_mode", response.parsed_body.dig("error", "code")

    post agent_api_v1_workspaces_path,
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { workspace: { name: "Bad Mode", access_mode: "public" } }, as: :json
    assert_response :unprocessable_entity
    assert_equal "invalid_access_mode", response.parsed_body.dig("error", "code")
  end

  test "an array-shaped cursor parameter is a 400, never a 500" do
    get agent_api_v1_workspaces_path, headers: bearer(@curator), params: { after: ["x"] }

    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
  end

  test "a create without a scalar name is a required-field 400, never a 500" do
    post agent_api_v1_workspaces_path,
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { workspace: { metadata: { "k" => "v" } } }, as: :json
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")

    # A non-scalar name is dropped by the allowlist and answers the same way.
    post agent_api_v1_workspaces_path,
      headers: bearer(@member).merge("Idempotency-Key" => SecureRandom.uuid),
      params: { workspace: { name: { "sneaky" => true } } }, as: :json
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end

  test "a transfer without its target field is a 400" do
    workspace = workspaces(:personal)

    post agent_api_v1_workspace_ownership_transfer_path(workspace.public_id),
      headers: bearer(@curator),
      params: { ownership_transfer: { lock_version: workspace.lock_version } }, as: :json
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")

    # A non-owner reader gets the authority answer before any target probe.
    post agent_api_v1_workspace_ownership_transfer_path(workspaces(:shared).public_id),
      headers: bearer(@member),
      params: { ownership_transfer: {
        target_user_public_id: SecureRandom.uuid_v7, lock_version: workspaces(:shared).lock_version,
      } }, as: :json
    assert_response :forbidden
    assert_equal "not_workspace_owner", response.parsed_body.dig("error", "code")
  end

  test "the family stays bearer-only and member-plane" do
    get agent_api_v1_workspaces_path
    assert_response :unauthorized

    executor = task_executors(:address)
    # The setup ceremony consumed this address's current epoch; advance it so
    # the fixture credential mints against a fresh one.
    advance_credential_epoch(executor)
    transport = create_bound_credential(executor: executor.reload, name: "T")
    get agent_api_v1_workspaces_path, headers: bearer_secret(transport.secret)
    assert_response :unauthorized
  end

  private

    def bearer(fixture)
      { "Authorization" => "Bearer #{fixture.secret}" }
    end

    def bearer_secret(secret)
      { "Authorization" => "Bearer #{secret}" }
    end
end
