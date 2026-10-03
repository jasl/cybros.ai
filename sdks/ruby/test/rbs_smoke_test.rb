require "test_helper"

class RbsSmokeTest < Minitest::Test
  def test_public_plane_composition_and_redaction_entrypoints
    credentials = CybrosAgent::DeviceFlow::Credentials.new(
      access_token: "member-token", executor_access_token: nil,
      refresh_token: "refresh-token", token_type: "Bearer", expires_in: 60
    )
    planes = CybrosAgent.planes_for(credentials, base_url: "http://127.0.0.1:3000")

    assert_instance_of CybrosAgent::Client, planes.client
    assert_nil planes.executor_client
    refute_includes CybrosAgent::Redaction.call("sk-cybros-api-v1-secret.value"), "secret.value"
  end

  def test_one_shot_input_estimate_is_present_on_the_typed_workspace_surface
    response = {
      "input_estimate" => {
        "input_tokens" => 24,
        "tokenizer_exact" => true,
        "catalog_input_token_limit" => 128_000,
        "model" => {
          "provider_id" => "dev",
          "model_ref" => "text",
          "reasoning_effort" => "medium",
        },
      },
    }
    transport = CybrosAgentTest::FakeTransport.new([[200, {}, response]])
    estimate = CybrosAgent::Client.new(
      base_url: "http://example.test", credential: "sk-member", transport: transport
    ).workspace("019f0000-0000-7000-8000-000000000101").one_shots.estimate_input(
      workload: "text_generation", model: "dev/text", input: "Say hi"
    )

    assert_equal 24, estimate.input_tokens
    assert_predicate estimate, :tokenizer_exact?
    assert_equal "dev", estimate.model.provider_id
  end
  # The executor boundary is on the typed surface too: an SDK that ships
  # signatures and then grows an untyped public context has two contracts.
  def test_the_executor_boundary_is_on_the_typed_executor_surface
    row = {
      "kind" => "tool_call",
      "agent_loop_public_id" => "019f0000-0000-7000-8000-000000000601",
      "workspace_public_id" => "019f0000-0000-7000-8000-000000000101",
      "conversation_public_id" => nil, "parent_public_id" => nil,
      "task_key" => "r1t0", "tool_name" => "read_file",
      "tool_input" => { "path" => "a.rb" }, "claimed" => false,
      "addressed_to" => { "role" => "runner", "executor_public_id" => "019f0000-0000-7000-8000-000000000701" },
    }
    transport = CybrosAgentTest::FakeTransport.new(
      [[200, {}, { "task" => row, "claim" => { "claim_token" => "tok-1" } }]]
    )
    claimed = CybrosAgent::ExecutorClient.new(
      base_url: "http://example.test", credential: "sk-transport", transport: transport
    ).inbox_task(agent_loop_public_id: row.fetch("agent_loop_public_id"), task_key: "r1t0").claim

    assert_instance_of CybrosAgent::Api::ClaimedTask, claimed
    assert_instance_of CybrosAgent::Api::InboxTask, claimed.task
    assert_equal row.fetch("workspace_public_id"), claimed.task.workspace_public_id
    assert_instance_of CybrosAgent::Api::AddressedTo, claimed.task.addressed_to
    assert_equal "tok-1", claimed.claim_token
  end

  # The shared cable double ships with the gem, unwired until a consumer
  # requires it by name; its surface is signed like the client it stands for.
  def test_the_shared_cable_double_is_on_the_typed_surface
    require "cybros_agent/test_support/fake_realtime"

    realtime = CybrosAgent::TestSupport::FakeRealtime.new
    subscription = realtime.connect.subscribe(channel: "AgentAPI::V1::ExecutorInboxChannel")
    assert_equal 1, realtime.deliver("AgentAPI::V1::ExecutorInboxChannel", { "event" => { "type" => "work_available" } })
    realtime.close

    frames = []
    subscription.each { |frame| frames << frame }
    assert_equal [{ "event" => { "type" => "work_available" } }], frames
    assert_predicate realtime, :closed?
  end
end
