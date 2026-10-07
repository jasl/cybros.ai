require "test_helper"
require_relative "../support/contract_clients"

class ApiIdentityContractPackTest < Minitest::Test
  include CybrosAgentTest::ContractClients

  def test_profile_and_executor_fixtures_parse_through_the_real_clients
    profiles = contract("profiles.json")
    profile = api_client(profiles.fetch("agent_api")).profile.fetch
    executor_fixture = contract("task_executors.json").fetch("valid_fixture")
    executor = executor_client(executor_fixture).executor

    assert_equal profiles.dig("agent_api", "member", "kind"), profile.member.kind
    assert_equal profiles.dig("agent_api", "credential", "plane"), profile.credential.plane
    assert_equal profiles.dig("agent_api", "configuration", "tool_definitions"),
      profile.configuration.tool_definitions
    assert_equal profiles.dig("agent_api", "configuration", "kernel_tools"), profile.configuration.kernel_tools
    assert_equal profiles.dig("agent_api", "configuration", "runner_executor_public_ids"), profile.configuration.runner_executor_public_ids
    assert_nil profile.configuration.runner_tool_names
    assert_equal profiles.dig("agent_api", "configuration", "approval_mode"),
      profile.configuration.approval_mode
    # THE FIFTH COLUMN: the rule list the pack's writer declared,
    # every key one of the six the kernel reads, carried opaque and frozen.
    rules = profiles.dig("agent_api", "configuration", "approval_rules")
    assert_equal rules, profile.configuration.approval_rules
    refute_empty rules, "the pack's declaration carries a rule list"
    assert_predicate profile.configuration.approval_rules, :frozen?
    assert_includes profiles.fetch("approval_modes"), profile.configuration.approval_mode
    rules.each do |rule|
      assert_empty rule.keys - profiles.fetch("approval_rule_keys"), "a rule's keys are the grammar's"
      assert_includes profiles.fetch("approval_verdicts"), rule.fetch("verdict")
    end
    assert_equal executor_fixture.dig("executor", "kind"), executor.executor.kind
    assert_equal executor_fixture.dig("executor", "status"), executor.executor.status
  end

  # THE NAMED DEFINITIONS LISTING: the pack's
  # presenter-rendered rows parse through the real client, and an unknown
  # scope word is carried.
  def test_the_named_agents_fixture_parses_through_the_real_client
    profiles = contract("profiles.json")
    rows = api_client(profiles.fetch("named_agents_fixture")).profile.agents.list

    assert_equal profiles.fetch("named_agents_fixture").fetch("agents").map { |row| row.fetch("name") }, rows.map(&:name)
    rows.each do |row|
      assert_includes profiles.fetch("definition_scopes"), row.scope
      assert_instance_of CybrosAgent::Api::AgentConfiguration, row.configuration
    end
    unknown = api_client(profiles.fetch("unknown_named_agent_scope_fixture")).profile.agents.list.first
    assert_equal profiles.fetch("unknown_value_fixture"), unknown.scope
    refute_predicate unknown, :published?
  end

  def test_additive_profile_and_executor_values_are_carried
    profiles = contract("profiles.json")
    profile = api_client(profiles.fetch("unknown_member_kind_fixture")).profile.fetch
    executors = contract("task_executors.json")
    executor = executor_client(executors.fetch("unknown_kind_fixture")).executor

    assert_equal profiles.fetch("unknown_value_fixture"), profile.member.kind
    assert_equal executors.fetch("unknown_value_fixture"), executor.executor.kind

    unknown_role = api_client(profiles.fetch("unknown_member_role_fixture")).profile.fetch
    unknown_plane = api_client(profiles.fetch("unknown_credential_plane_fixture")).profile.fetch
    unknown_status = executor_client(executors.fetch("unknown_status_fixture")).executor

    assert_equal profiles.fetch("unknown_value_fixture"), unknown_role.member.role
    assert_equal profiles.fetch("unknown_value_fixture"), unknown_plane.credential.plane
    assert_equal executors.fetch("unknown_value_fixture"), unknown_status.executor.status
  end

  def test_workspace_creator_kind_is_parsed_and_unknown_values_are_carried
    workspaces = contract("workspaces.json")
    valid_fixture = workspaces.fetch("valid_full_fixture")
    valid = api_client(valid_fixture).workspaces.fetch("fixture-workspace")
    unknown_fixture = {
      "workspace" => workspaces.fetch("unknown_creator_kind_fixture"),
    }
    unknown = api_client(unknown_fixture).workspaces.fetch("fixture-workspace")

    assert_equal valid_fixture.dig("workspace", "creator", "kind"), valid.creator.kind
    assert_equal contract("meta.json").fetch("unknown_value_fixture"), unknown.creator.kind
  end

  def test_terminal_executor_and_workspace_values_parse_without_becoming_authority
    executors = contract("task_executors.json")
    executor = executor_client(executors.fetch("terminal_status_fixture")).executor
    workspaces = contract("workspaces.json")
    terminal = workspaces.fetch("terminal_state_fixture")
    page = api_client(
      "workspaces" => [terminal],
      "pagination" => { "next_after" => nil }
    ).workspaces.list
    unknown_access_mode = api_client(
      "workspaces" => [workspaces.fetch("unknown_access_mode_fixture")],
      "pagination" => { "next_after" => nil }
    ).workspaces.list.items.fetch(0)

    assert_equal "revoked", executor.executor.status
    assert_equal "deleted", page.items.fetch(0).state
    assert_equal workspaces.fetch("unknown_access_mode_fixture").fetch("access_mode"),
      unknown_access_mode.access_mode
  end

  def test_device_flow_fixtures_enforce_closed_plane_and_error_behavior
    oauth = contract("oauth.json")
    client, = device_flow_client([
      [200, {}, oauth.fetch("valid_device_authorization_fixture")],
      [200, {}, oauth.fetch("valid_agent_token_fixture")],
    ])
    authorization = client.request_authorization(
      agent_identifier: "fixture-agent",
      agent_display_name: "Fixture agent",
      executor_display_name: "Fixture executor"
    )
    credentials = client.poll(authorization)

    assert_predicate credentials, :member_plane?
    assert_predicate credentials, :executor_plane?
    refute_predicate credentials, :runner_plane?

    # The combined fixture parses through the:combined branch:
    # three planes, the runner half in the transport-led shape.
    combined_client, combined_transport = device_flow_client([
      [200, {}, oauth.fetch("valid_device_authorization_fixture")],
      [200, {}, oauth.fetch("valid_combined_token_fixture")],
    ])
    combined_authorization = combined_client.request_authorization(
      agent_identifier: "fixture-agent",
      agent_display_name: "Fixture agent",
      executor_display_name: "Fixture executor",
      runner: { identifier: "fixture-rho", display_name: "Fixture rho" }
    )
    assert_equal :combined, combined_authorization.branch
    assert_equal [
      ["/oauth/device_authorization", oauth.fetch("agent_authorization_request").merge(
        "registration_identifier" => "fixture-rho", "runner_display_name" => "Fixture rho"
      )],
    ], combined_transport.calls
    combined = combined_client.poll(combined_authorization)
    assert_predicate combined, :runner_plane?
    assert_equal oauth.dig("valid_combined_token_fixture", "runner", "access_token"),
      combined.runner_half.executor_access_token
    assert_equal oauth.dig("valid_combined_token_fixture", "runner", "refresh_token"),
      combined.runner_half.refresh_token
    refute_predicate combined.runner_half, :member_plane?

    unknown_plane_client, = device_flow_client([
      [200, {}, oauth.fetch("valid_device_authorization_fixture")],
      [200, {}, oauth.fetch("unknown_plane_fixture")],
    ])
    unknown_authorization = unknown_plane_client.request_authorization(
      agent_identifier: "fixture-agent",
      agent_display_name: "Fixture agent",
      executor_display_name: "Fixture executor"
    )

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      unknown_plane_client.poll(unknown_authorization)
    end

    unknown_token_type_client, = device_flow_client([
      [200, {}, oauth.fetch("valid_device_authorization_fixture")],
      [200, {}, oauth.fetch("unknown_token_type_fixture")],
    ])
    unknown_token_type_authorization = unknown_token_type_client.request_authorization(
      agent_identifier: "fixture-agent",
      agent_display_name: "Fixture agent",
      executor_display_name: "Fixture executor"
    )
    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
      unknown_token_type_client.poll(unknown_token_type_authorization)
    end

    unknown_error = oauth.fetch("unknown_error_fixture").fetch("body").fetch("error")
    assert_instance_of CybrosAgent::DeviceFlow::ServerError,
      CybrosAgent::DeviceFlow.for_oauth_error(unknown_error)

    terminal_error = oauth.fetch("terminal_error_fixture").fetch("body").fetch("error")
    assert_instance_of CybrosAgent::DeviceFlow::AuthorizationLostError,
      CybrosAgent::DeviceFlow.for_oauth_error(terminal_error)
  end

  def test_device_flow_requests_and_cancellation_winner_match_the_pack
    oauth = contract("oauth.json")
    agent_client, agent_transport = device_flow_client([
      [200, {}, oauth.fetch("valid_device_authorization_fixture")],
      [200, {}, oauth.fetch("valid_agent_token_fixture")],
    ])
    authorization = agent_client.request_authorization(
      agent_identifier: "fixture-agent",
      agent_display_name: "Fixture agent",
      executor_display_name: "Fixture executor"
    )
    agent_client.poll(authorization)

    assert_equal [
      ["/oauth/device_authorization", oauth.fetch("agent_authorization_request")],
      ["/oauth/token", oauth.fetch("device_token_request")],
    ], agent_transport.calls

    runner_client, runner_transport = device_flow_client([
      [200, {}, oauth.fetch("valid_device_authorization_fixture")],
    ])
    runner_client.request_runner_authorization(
      registration_identifier: "fixture-runner",
      runner_display_name: "Fixture runner"
    )
    assert_equal [
      ["/oauth/device_authorization", oauth.fetch("runner_authorization_request")],
    ], runner_transport.calls

    refresh_client, refresh_transport = device_flow_client([
      [200, {}, oauth.fetch("valid_agent_token_fixture")],
    ])
    refresh_client.rotate(refresh_token: "fixture-refresh-token")
    assert_equal [
      ["/oauth/token", oauth.fetch("refresh_token_request")],
    ], refresh_transport.calls

    cancellation = oauth.fetch("consumed_cancellation_fixture")
    cancel_client, cancel_transport = device_flow_client([
      [200, {}, oauth.fetch("valid_device_authorization_fixture")],
      [cancellation.fetch("status"), cancellation.fetch("headers"), cancellation.fetch("body")],
    ])
    cancel_authorization = cancel_client.request_authorization(
      agent_identifier: "fixture-agent",
      agent_display_name: "Fixture agent",
      executor_display_name: "Fixture executor"
    )
    assert_equal :consumed, cancel_client.cancel_authorization(cancel_authorization)
    assert_equal [
      ["/oauth/device_authorization", oauth.fetch("agent_authorization_request")],
      ["/oauth/device_authorization/cancellation", oauth.fetch("cancellation_request")],
    ], cancel_transport.calls

    revocation = oauth.fetch("valid_revocation_fixture")
    revoke_client, revoke_transport = device_flow_client([
      [revocation.fetch("status"), revocation.fetch("headers", {}), revocation["body"]],
    ])
    revoke_client.revoke(token: "fixture-access-token")
    assert_equal [
      ["/oauth/revoke", oauth.fetch("revocation_request")],
    ], revoke_transport.calls
  end

  # THE MODEL PLANE'S PACK: the listing's row parses
  # through the real catalog reader with its capabilities and pricing
  # intact; the refused row names the resolver's word; the four pricing
  # states and a lane parse through the providers reader; and a state,
  # reason or credential kind this gem predates is carried, never refused.
  def test_the_models_fixtures_parse_through_the_real_readers_and_unknown_words_are_carried
    models = contract("models.json")
    listed = api_client(models.fetch("valid_fixture")).models.list
    assert_equal 1, listed.length
    model = listed.fetch(0)
    assert_instance_of CybrosAgent::Api::ModelCatalog::Model, model
    assert_equal models.fetch("row_projection").sort, CybrosAgent::Api::ModelCatalog::Model.members.map(&:to_s).sort,
      "the typed row carries exactly the presenter's projection"
    assert_predicate model, :available?
    assert_predicate model, :visible?
    assert_predicate model, :tool_calls?
    refute_respond_to model, :parallel_tool_calls?, "no row states a parallel fact (owner 2026-09-16)"
    assert_equal models.fetch("capabilities_projection").sort, model.capabilities.keys.sort
    assert_predicate model.pricing, :priced?
    assert_equal models.fetch("pricing_projection").sort,
      CybrosAgent::Api::ModelCatalog::Pricing.members.map(&:to_s).sort
    assert_includes models.fetch("workloads"), model.workload

    refused = platform_client("models" => [models.fetch("unavailable_fixture")]).models.list.fetch(0)
    refute_predicate refused, :available?
    assert_includes models.fetch("unavailable_reasons"), refused.unavailable_reason

    hidden = platform_client("models" => [models.fetch("hidden_fixture")]).models.list.fetch(0)
    refute_predicate hidden, :visible?
    refute_predicate hidden, :available?
    assert_equal "model_hidden", hidden.unavailable_reason
    assert_equal model.pricing, hidden.pricing

    unavailable = platform_client("models" => [models.fetch("model_unavailable_fixture")]).models.list.fetch(0)
    refute_predicate unavailable, :visible?
    refute_predicate unavailable, :available?
    assert_equal "model_unavailable", unavailable.unavailable_reason
    assert_equal model.pricing, unavailable.pricing

    states = %w[known_free_fixture unmetered_fixture cost_unknown_fixture].map do |name|
      platform_client("models" => [models.fetch(name)]).models.list.fetch(0).pricing.state
    end
    assert_equal models.fetch("pricing_states") - ["priced"], states
    assert_predicate api_client("models" => [models.fetch("known_free_fixture")]).models.list.fetch(0).pricing, :free?

    lanes = api_client(models.fetch("valid_providers_fixture")).model_providers.list
    assert_equal 3, lanes.length
    lane = lanes.fetch(0)
    assert_equal models.fetch("provider_projection").sort, CybrosAgent::Api::ModelProviders::Lane.members.map(&:to_s).sort
    assert_predicate lane, :ready?
    assert_predicate lane, :api_key?
    assert_nil lane.unavailable_until
    assert_includes models.fetch("credentials"), lane.credentials
    assert_predicate lanes.fetch(1), :configured?, "a lane that needs no secret is configured on its own"
    # THE FLOORED LANE: the provider's clock as the kernel spells
    # it — a string, and a lane that is otherwise ready stays ready.
    floored = lanes.fetch(2)
    assert_equal models.dig("floored_provider_fixture", "model_provider", "unavailable_until"), floored.unavailable_until
    assert_kind_of String, floored.unavailable_until
    assert_predicate floored, :ready?

    unknown = models.fetch("unknown_value_fixture")
    assert_equal unknown,
      platform_client("models" => [models.fetch("unknown_unavailable_reason_fixture")]).models.list.fetch(0).unavailable_reason
    assert_equal unknown,
      api_client("models" => [models.fetch("unknown_pricing_state_fixture")]).models.list.fetch(0).pricing.state
    assert_equal unknown,
      api_client("model_providers" => [models.fetch("unknown_credentials_fixture")]).model_providers.list.fetch(0)
        .credentials
    error = models.fetch("valid_error_fixture")
    assert_equal models.dig("error_statuses", "model_plane_unavailable"), error.fetch("status")
  end
end
