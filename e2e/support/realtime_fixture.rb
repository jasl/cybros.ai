require "support/actor_provisioning"
require "support/platform_http"
require "support/secret_hygiene"
require "support/runner_grant"
require "support/steward_session"

module E2E
  module RealtimeFixture
    class Log
      def info(*, **) = nil
      def warn(*, **) = nil
    end

    class FaultTransport
      attr_accessor :unavailable
      attr_reader :unavailable_claim_reads

      def initialize(base_url:)
        @http = CybrosAgent::HttpTransport.new(base_url: base_url)
        @unavailable_claim_reads = 0
      end

      def call(path, **request)
        if @unavailable
          @unavailable_claim_reads += 1 if path.end_with?("/claim")
          raise CybrosAgent::TransportError, "control unavailable"
        end

        @http.call(path, **request)
      end
    end

    private

      def prepare_realtime(detached: false, start: true, additional_tools: [], application_runner: true)
        base_url = E2E.base_url
        human = E2E::ActorProvisioning.world(base_url).rho_steward
        E2E::SessionSignInBudget.consume
        session = CybrosAgent::Platform::Sessions.new(base_url: base_url).create(email: human.email, password: human.password)
        @platform = CybrosAgent::PlatformClient.new(base_url: base_url, credential: E2E::SecretHygiene.register(session.token))
        http = E2E::PlatformHttp.new(base_url)
        agent = http.post("/api/v1/agents", body: { agent: { display_name: "Realtime handler test" } }, bearer: session.token)
        assert_equal 201, agent.status
        @agent_id = agent.body.fetch("agent").fetch("public_id")
        path = "/api/v1/agents/#{@agent_id}"
        member_key = issue_realtime_key(http, session, "#{path}/api_keys")
        member = CybrosAgent::Client.new(base_url: base_url, credential: member_key)
        transport = FaultTransport.new(base_url: base_url)
        credential = if application_runner
          issue_realtime_key(http, session, "#{path}/executor/api_keys")
        else
          independent_terminal_credential(base_url, human)
        end
        executor = CybrosAgent::ExecutorClient.new(base_url: base_url, credential: credential, transport: transport)
        executor_id = executor.executor.executor.public_id
        services = { "runner" => { "tools" => [{ "name" => "realtime_probe", "timeout_ms" => 120_000,
          "effect_profile" => { "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
            "idempotency" => "intrinsic", "reconciliation" => "none" } }] + additional_tools } }
        services["agent"] = { "tools" => [] } if application_runner
        executor.announce(services: services)
        @independent_runner_credential = credential unless application_runner
        workspace = member.workspaces.create(name: "Realtime handler", idempotency_key: SecureRandom.uuid).workspace
        # Extra credentials may wait out issuance limits before any Task starts.
        yield http, session, path if block_given?
        E2E.hosts.start
        runs = member.workspace(workspace.public_id).runs
        key = CybrosAgent::Api::RunContext::TOOL_CALL_TASK_KEY
        if !start
          return [base_url, path, http, session, member_key, member, transport, executor, key, workspace]
        end
        if detached
          created = runs.create(approval_mode: "bypass", prompt_mechanism: "raw", idempotency_key: SecureRandom.uuid,
            steps: [{ "tool" => { "name" => "realtime_probe", "key" => key, "detached" => true, "wake" => "passive",
              "route" => { "kind" => "runner", "runner_executor_public_id" => executor_id } } },
              { "ask" => { "key" => "mainline", "prompt" => "Independent mainline work" } }])
          @run = runs.run(created.run.public_id)
          @run.start
        else
          @run = runs.start_tool_call(runner_executor_public_id: executor_id, tool: "realtime_probe", input: {}, idempotency_key: SecureRandom.uuid)
        end
        await { @run.task(key).task.status == "dispatched" }
        [base_url, path, http, session, member_key, member, transport, executor, key, workspace]
      end

      # The browser viewer is its own application announcement writer. Its
      # externally driven terminal worker uses an independent machine address.
      def independent_terminal_credential(base_url, human)
        device = CybrosAgent::DeviceFlow::Client.new(base_url: base_url)
        E2E::DeviceAuthorizationBudget.consume
        authorization = device.request_runner_authorization(
          registration_identifier: "e2e-terminal-#{SecureRandom.uuid}", runner_display_name: "Terminal fixture")
        actor = E2E::StewardSession.actor(base_url: base_url, human: human)
        E2E::RunnerGrant.visit_connection(actor: actor, authorization: authorization)
        E2E::RunnerGrant.connect_in_browser(actor: actor, authorization: authorization)
        device.await_credentials(authorization).executor_access_token
      end

      def issue_realtime_key(http, session, key_path)
        response = http.post(key_path, body: { api_key: { name: "Realtime" } }, bearer: session.token, retry_rate_limit: true)
        assert_equal 201, response.status
        E2E::SecretHygiene.register(response.body.fetch("secret"))
      end

      def await(seconds: 10, message: "Realtime condition did not converge")
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        until yield
          flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.02
        end
      end
  end
end
