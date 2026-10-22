require "test_helper"
require_relative "support/contract_fixtures"

class PlatformManagedRunnersTest < Minitest::Test
  def pack = CybrosAgentTest::ContractFixtures.pack("platform_runners.json")

  def client(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::PlatformClient.new(base_url: "https://nexus.example", credential: "platform-key", transport: @transport)
  end

  def test_manager_list_keeps_filters_pagination_measurement_and_execution_eligibility_separate
    fixture = pack.fetch("valid_runners_fixture")
    fixture.fetch("pagination")["next_after"] = "next opaque cursor"
    page = client([[200, {}, fixture]]).runners.list(after: "cursor", limit: 2, kind: "runner", status: "active", order: "desc")
    runner = page.items.first

    assert_instance_of CybrosAgent::Platform::ManagedRunnerPage, page
    assert_instance_of CybrosAgent::Platform::ManagedRunner, runner
    assert_equal fixture.dig("runners", 0, "manager_public_id"), runner.manager_public_id
    assert_equal "user_private", runner.assignment_scope
    assert_equal "ready", runner.credential_readiness
    assert runner.eligible_for_current_user
    assert_equal fixture.fetch("measured_at"), page.measured_at
    assert_equal "next opaque cursor", page.next_after
    request = @transport.requests.last
    assert_equal :get, request.fetch(:method)
    assert_equal "/api/v1/runners", request.fetch(:path)
    assert_equal "platform-key", request.fetch(:credential)
    assert_equal({ "after" => "cursor", "limit" => 2, "kind" => "runner", "status" => "active", "order" => "desc" }, request.fetch(:params))
  end

  def test_manager_detail_uses_existing_announcements_and_preserves_the_measurement_envelope
    fixture = pack.fetch("valid_runner_fixture")
    snapshot = client([[200, {}, fixture]]).runners.fetch("runner/one")
    runner = snapshot.runner

    assert_instance_of CybrosAgent::Platform::ManagedRunnerSnapshot, snapshot
    assert_instance_of CybrosAgent::Platform::ManagedRunnerDetail, runner
    assert_instance_of CybrosAgent::Api::ServedTool, runner.services.runner.tools.first
    assert_instance_of CybrosAgent::Api::ServedDocument, runner.services.runner.documents.first
    assert_equal fixture.dig("runner", "services", "runner", "tools", 0, "input_schema"), runner.services.runner.tools.first.input_schema
    assert_equal fixture.dig("runner", "services", "runner", "documents", 0, "name"), runner.services.runner.documents.first.name
    assert_equal fixture.dig("runner", "services", "runner", "environment"), runner.services.runner.environment
    assert_equal fixture.dig("runner", "registered_at"), runner.registered_at
    assert_equal fixture.fetch("measured_at"), snapshot.measured_at
    assert_equal "/api/v1/runners/runner%2Fone", @transport.requests.last.fetch(:path)
  end

  def test_revoked_tool_provider_and_unknown_facts_remain_inspectable
    fixture = pack.fetch("valid_runner_fixture")
    fixture.fetch("runner").merge!("kind" => "tool_provider", "status" => "revoked",
      "assignment_scope" => "user_private",
      "credential_readiness" => "zz_future_readiness", "presence" => "zz_future_presence")
    runner = client([[200, {}, fixture]]).runners.fetch("provider").runner

    assert_equal "tool_provider", runner.kind
    assert_equal "revoked", runner.status
    assert_equal ["runner"], runner.service_roles
    assert_equal "zz_future_readiness", runner.credential_readiness
    assert_equal "zz_future_presence", runner.presence
    assert runner.eligible_for_current_user
  end

  def test_management_projection_requires_its_eligibility_boolean_and_measurement
    fixture = pack.fetch("valid_runner_fixture")
    fixture.fetch("runner").delete("eligible_for_current_user")
    assert_raises(CybrosAgent::Api::MalformedResponse) { client([[200, {}, fixture]]).runners.fetch("runner") }

    page = pack.fetch("valid_runners_fixture")
    page.delete("measured_at")
    assert_raises(CybrosAgent::Api::MalformedResponse) { client([[200, {}, page]]).runners.list }
  end
end
