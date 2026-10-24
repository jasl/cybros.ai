require "test_helper"
require "timeout"
require "support/actor_provisioning"
require "support/steward_session"
require "support/peer_program"
require_relative "../support/fake_executor"

class FakeExecutorTest < Minitest::Test
  def test_sdk_agent_calls_independent_runner_and_another_address_cannot_claim
    base_url = E2E.base_url
    human = E2E::ActorProvisioning.world(base_url).shared_human
    actor = E2E::StewardSession.actor(base_url: base_url, human: human)
    agent = E2E::PeerProgram.pair(base_url: base_url, actor: actor, name: "fake-agent")
    application = E2E::FakeExecutor.new(base_url: base_url, credential: agent.executor_credential)
      .announce(roles: %w[agent runner])
    device = CybrosAgent::DeviceFlow::Client.new(base_url: base_url, sleeper: ->(_seconds) { sleep 0.2 })
    E2E::DeviceAuthorizationBudget.consume
    authorization = device.request_runner_authorization(registration_identifier: "fake-runner-#{SecureRandom.hex(4)}",
      runner_display_name: "Protocol fake Runner")
    E2E::RunnerGrant.visit_connection(actor: actor, authorization: authorization)
    E2E::RunnerGrant.connect_in_browser(actor: actor, authorization: authorization)
    runner = E2E::FakeExecutor.new(base_url: base_url,
      credential: device.await_credentials(authorization).executor_access_token).announce
    workspace = agent.client.workspace(agent.client.workspaces.create(
      name: "Fake peers", idempotency_key: SecureRandom.uuid).workspace.public_id)
    E2E.hosts.start
    run = workspace.runs.start_tool_call(runner_executor_public_id: runner.address.public_id,
      tool: "echo", input: { "value" => "SDK round trip" }, idempotency_key: SecureRandom.uuid)
    key = CybrosAgent::Api::RunContext::TOOL_CALL_TASK_KEY
    await { run.task(key).task.status == "dispatched" }
    assert_empty application.client.inbox.list.items
    refusal = assert_raises(CybrosAgent::Api::Conflict) do
      application.client.inbox_task(run_public_id: run.run_public_id, task_key: key).claim
    end
    assert_equal "not_addressed_here", refusal.code
    runner.sweep
    await { run.fetch.status == "completed" }
    assert_equal 1, runner.claims.length
    assert_equal runner.address.public_id, run.task(key).task.claimed_by.executor_public_id
    assert_includes JSON.generate(run.task(key).to_h), "SDK round trip"
    assert_equal %w[agent runner], application.client.executor.executor.service_roles.sort
    E2E::DeviceAuthorizationBudget.consume
    provider_authorization = device.request_runner_authorization(
      registration_identifier: "fake-provider-#{SecureRandom.hex(4)}",
      runner_display_name: "Protocol fake provider", executor_kind: "tool_provider")
    E2E::RunnerGrant.visit_connection(actor: actor, authorization: provider_authorization)
    E2E::RunnerGrant.connect_in_browser(actor: actor, authorization: provider_authorization)
    provider = E2E::FakeExecutor.new(base_url: base_url,
      credential: device.await_credentials(provider_authorization).executor_access_token).announce(tools: ["pool_echo"])
    created = workspace.runs.create(steps: [{ "tool" => {
      "key" => "provider-call", "name" => "pool_echo", "input" => { "value" => "pool result" },
    } }], idempotency_key: SecureRandom.uuid, approval_mode: "bypass", prompt_mechanism: "raw")
    run = workspace.run(created.run.public_id)
    run.start
    await { run.task("provider-call").task.status == "dispatched" }
    assert_empty runner.client.inbox.list.items
    assert_empty application.client.inbox.list.items
    provider.sweep
    await { run.fetch.status == "completed" }
    task = run.task("provider-call")
    assert_equal "tool_provider", task.task.addressed_to.role
    assert_nil task.task.addressed_to.executor_public_id
    assert_equal provider.address.public_id, task.task.claimed_by.executor_public_id
    assert_includes task.output, "pool result"

    # Withdrawing a role affects new work, not an already granted claim.
    run, door, claim = claim_run(workspace, application)
    application.announce(roles: ["agent"])
    assert door.claim_status(claim_token: claim.claim_token).active
    checkpoint = { "hash" => "opaque-checkpoint", "store" => "foreign-format",
      "extension" => { "version" => 7, "data" => [true, nil, "unchanged"] } }
    door.commit(claim_token: claim.claim_token, outcome: "completed", is_error: false,
      content: "kept", metadata: { "checkpoint" => checkpoint })
    await { run.fetch.status == "completed" }
    assert_equal checkpoint, run.task(key).metadata.fetch("checkpoint")
    assert_equal application.address.public_id, run.task(key).task.claimed_by.executor_public_id
    assert_equal ["agent"], application.client.executor.executor.service_roles

    run, door, claim = claim_run(workspace, runner)
    renewed = door.extend(claim_token: claim.claim_token, timeout_ms: 30_000)
    assert_equal claim.claim_token, renewed.claim_token
    assert_operator Time.iso8601(renewed.deadline_at), :>=, Time.iso8601(claim.deadline_at)
    run.stop(force: true)
    refute door.claim_status(claim_token: claim.claim_token).active
    stopped = run.task(key).to_h
    door.commit(claim_token: claim.claim_token, outcome: "completed", is_error: false, content: "too late")
    assert_equal stopped, run.task(key).to_h

    # A late commit itself reaches authoritative deadline settlement.
    run, door, claim = claim_run(workspace, runner)
    expiring = door.extend(claim_token: claim.claim_token, timeout_ms: 1_000)
    # The public timestamp has whole-second precision; pass that entire second.
    sleep 0.1 while Time.now <= Time.iso8601(expiring.deadline_at) + 1
    door.commit(claim_token: claim.claim_token, outcome: "completed", is_error: false, content: "expired")
    assert_equal "timed_out", run.task(key).task.status
    refute door.claim_status(claim_token: claim.claim_token).active
    refute_includes run.task(key).output.to_s, "expired"
    run.stop(force: true)
    assert_empty Gem.loaded_specs.keys.grep(/\Arho(?:-|\z)/)
    refute $LOADED_FEATURES.any? { |path| path.include?("/agents/rho/") }
  ensure
    run&.stop(force: true) if run && run.fetch.status == "running"
  end

  private

    def claim_run(workspace, executor)
      run = workspace.runs.start_tool_call(runner_executor_public_id: executor.address.public_id,
        tool: "echo", input: {}, idempotency_key: SecureRandom.uuid)
      key = CybrosAgent::Api::RunContext::TOOL_CALL_TASK_KEY
      await { run.task(key).task.status == "dispatched" }
      door = executor.client.inbox_task(run_public_id: run.run_public_id, task_key: key)
      [run, door, door.claim]
    end

    def await
      Timeout.timeout(30) do
        sleep 0.1 until yield
      end
    end
end
