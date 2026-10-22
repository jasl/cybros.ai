# Run from e2e/: bundle exec ruby -Itest manual/realtime_transport/nexus_probe.rb
require "test_helper"
require "open3"
require "support/actor_provisioning"
require "support/platform_http"
require "support/secret_hygiene"

class RealtimeNexusProbe < Minitest::Test
  def test_existing_task_authority_drives_transport_gate_and_stop
    base_url = E2E.base_url
    human = E2E::ActorProvisioning.world(base_url).rho_steward
    E2E::SessionSignInBudget.consume
    session = CybrosAgent::Platform::Sessions.new(base_url: base_url).create(email: human.email, password: human.password)
    @platform = CybrosAgent::PlatformClient.new(base_url: base_url, credential: E2E::SecretHygiene.register(session.token))
    http = E2E::PlatformHttp.new(base_url)
    agent = http.post("/api/v1/agents", body: { agent: { display_name: "Transport probe" } }, bearer: session.token)
    assert_equal 201, agent.status
    @agent_id = agent.body.fetch("agent").fetch("public_id")
    path = "/api/v1/agents/#{@agent_id}"
    runner_path = "#{path}/executor/api_keys"
    issue = ->(key_path) do
      response = http.post(key_path, body: { api_key: { name: "Probe" } }, bearer: session.token)
      assert_equal 201, response.status
      E2E::SecretHygiene.register(response.body.fetch("secret"))
    end
    member_key = issue.call("#{path}/api_keys")
    member = CybrosAgent::Client.new(base_url: base_url, credential: member_key)
    executor = CybrosAgent::ExecutorClient.new(base_url: base_url, credential: issue.call(runner_path))
    executor_id = executor.executor.executor.public_id
    executor.announce(services: { "agent" => { "tools" => [] }, "runner" => { "tools" => [{ "name" => "terminal_probe", "effect_profile" =>
      { "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
        "idempotency" => "intrinsic", "reconciliation" => "none" }, "timeout_ms" => 120_000 }] } })
    workspace = member.workspaces.create(name: "Transport probe", idempotency_key: SecureRandom.uuid).workspace
    E2E.hosts.start
    @run = member.workspace(workspace.public_id).runs.start_tool_call(
      runner_executor_public_id: executor_id, tool: "terminal_probe", input: {}, idempotency_key: SecureRandom.uuid)
    task = executor.inbox_task(run_public_id: @run.run_public_id, task_key: CybrosAgent::Api::RunContext::TOOL_CALL_TASK_KEY)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      row = @run.task(CybrosAgent::Api::RunContext::TOOL_CALL_TASK_KEY).task
      break if row.status == "dispatched" && row.addressed_to&.executor_public_id == executor_id
      flunk "Task did not dispatch: #{row.status}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
    claim = task.claim
    assert task.claim_status(claim_token: claim.claim_token).active?
    task.extend(claim_token: claim.claim_token, timeout_ms: 120_000)
    @stdin, stdout, @wait = Open3.popen2("python3", File.join(__dir__, "serve.py"))
    ready = JSON.parse(stdout.gets)
    @urls = ready.fetch("urls")
    assert_equal "host", ready.fetch("connection").fetch("pair").fetch("local")
    refresh(task, claim.claim_token)
    refute peer("agent", "/sample", {}).key?("error")
    pid = peer("runner", "/stats").fetch("pid")

    # Omitting refresh models unavailable control HTTP without breaking the live data path.
    sleep 1.1
    refute peer("runner", "/stats").fetch("authorized")
    assert peer("agent", "/sample", {}).key?("error")
    assert task.claim_status(claim_token: claim.claim_token).active?
    assert_equal pid, peer("runner", "/stats").fetch("pid")
    refresh(task, claim.claim_token)
    refute peer("agent", "/sample", {}).key?("error")
    error = assert_raises(CybrosAgent::Api::Conflict) { task.claim_status(claim_token: SecureRandom.hex(24)) }
    assert_equal "not_claimant", error.code

    CybrosAgent::DeviceFlow::Client.new(base_url: base_url).revoke(token: member_key)
    assert_raises(CybrosAgent::Api::Unauthorized) { @run.fetch }
    %w[agent runner].each { |role| peer(role, "/gate", { Allow: false }) }
    assert peer("agent", "/sample", {}).key?("error")
    assert task.claim_status(claim_token: claim.claim_token).active?, "member revocation is not a task cancellation"
    member = CybrosAgent::Client.new(base_url: base_url, credential: issue.call("#{path}/api_keys"))
    @run = member.workspace(workspace.public_id).run(@run.run_public_id)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @run.stop(force: true)
    accepted = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    refute task.claim_status(claim_token: claim.claim_token).active?
    observed = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    %w[agent runner].each { |role| peer(role, "/gate", { Terminal: true }) }
    assert peer("runner", "/stats").fetch("child_exited")
    reaped = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert peer("agent", "/sample", {}).key?("error")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      break if @run.fetch.terminal?
      flunk "Stop did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
    status = @run.fetch.status
    assert_equal "canceled", status
    report = { actual_task_and_claim: true, expired_gate_preserved_claim_and_pid: true,
      member_revocation_refused: true, wrong_claim_refused: true, stop_status: status,
      stop_http_ms: (accepted - started) * 1000, stop_to_claim_observation_ms: (observed - accepted) * 1000,
      observation_to_child_reaped_ms: (reaped - observed) * 1000,
      limitation: "Sequential public reads, fixture signaling and gate; not a production authorization projection or Runner handler" }
    directory = File.expand_path("../../artifacts/realtime_transport", __dir__)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "nexus.json"), JSON.pretty_generate(report) + "\n")
    puts JSON.generate(report)
  ensure
    @stdin&.close
    @wait&.value
    @run.stop(force: true) if @run && !@run.fetch.terminal?
    @platform&.agents&.agent(@agent_id)&.remove if @agent_id
    @platform&.session&.revoke
  end

  private

    def peer(role, path, body = nil)
      http = E2E::PlatformHttp.new(@urls.fetch(role))
      response = body ? http.post(path, body: body) : http.get(path)
      assert_equal 200, response.status
      response.body
    end

    def refresh(task, claim_token)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      run = @run.fetch
      active = task.claim_status(claim_token: claim_token).active?
      remaining = 1000 - ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).ceil
      assert active && !run.terminal? && remaining.positive?
      %w[agent runner].each do |role|
        remaining = [1000 - ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).ceil, 0].max
        peer(role, "/gate", { Allow: true, ValidForMS: remaining })
      end
    end
end
