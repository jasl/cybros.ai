require "net/http"
require_relative "host_fixture"

# WHAT EVERY DAEMON TEST STANDS ON: a booted daemon under a temporary home,
# stopped in teardown, driven over its own HTTP surface with the bearer its
# announcement names. Shared by the per-collaborator files under test/daemon
# and the per-extension files under test/extensions, so a test moves between
# them without a helper moving too.
module RhoTest
  module DaemonHarness
    IDENTITY = Data.define(:user_public_id, :executor_public_id, :runner_executor_public_id).new(
      user_public_id: "user-1", executor_public_id: "executor-1", runner_executor_public_id: nil
    )
    # The same Profile holding a runner row of its own (full mode): what a
    # test that marks "this machine's own" runner adopts.
    RUNNER_IDENTITY = IDENTITY.with(runner_executor_public_id: "0199-runner")

    def setup
      @root = Dir.mktmpdir("rho-daemon")
      @daemons = []
    end

    def teardown
      @daemons.each { |daemon| daemon.stop if daemon.running? }
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    end

    def boot(base_url: "https://nexus.example", root: @root, **options)
      if (sleeper = options[:sleeper])
        # A fake may advance a clock or record waits without doing IO. The
        # daemon's sibling fibers must still get the yield a real sleep gives.
        options[:sleeper] = ->(seconds) { sleeper.call(seconds); sleep 0.001 }
      end
      daemon = Rho::Daemon.boot(home: Rho::Home.resolve(base_url: base_url, root: root), **options)
      @daemons << daemon
      daemon
    end

    def host_store(daemon = @daemons.last) = RhoTest::HostFixture.new(daemon)

    def announcement(daemon) = Rho::StateFile.new(daemon.home.announcement_path).read

    def bearer(daemon) = announcement(daemon)["bearer"]

    def request(daemon, verb, path, token: nil, body: nil)
      uri = URI.join(daemon.endpoint, path)
      klass = { post: Net::HTTP::Post, put: Net::HTTP::Put, patch: Net::HTTP::Patch }.fetch(verb, Net::HTTP::Get)
      message = klass.new(uri)
      message["Authorization"] = "Bearer #{token}" if token
      unless body.nil?
        # THE ROUTER DEMANDS IT. `text/plain` is CORS-safelisted, so a body sent
        # without this header is exactly the drive-by write the check refuses —
        # a test that omitted it would be testing a request no client makes.
        message["Content-Type"] = "application/json"
        message.body = JSON.generate(body)
      end
      Net::HTTP.start(uri.host, uri.port) { |http| http.request(message) }
    end

    def await_state(daemon, state, token:, timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        body = JSON.parse(request(daemon, :get, "/status", token: token).body)
        return body if body["state"] == state
        raise "still #{body["state"]} after #{timeout}s (#{body.inspect})" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end
    end

    def connected_boot(**options)
      boot(device_flow: connection_device_flow, api_transport: NexusDoubles::FakeAgentApi.new, **options)
    end

    def connection_device_flow(oauth = NexusDoubles::FakeOAuth.new)
      CybrosAgent::DeviceFlow::Client.new(
        base_url: "https://nexus.example", transport: oauth, sleeper: ->(_seconds) { nil }
      )
    end

    # Waiting for the daemon's own state is not enough here: it is already
    # `disconnected`, so the poller's outcome has to be what we wait on.
    def start_and_fail(daemon, token:)
      request(daemon, :post, "/device/start", token: token)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      loop do
        body = JSON.parse(request(daemon, :get, "/status", token: token).body)
        return body if body.dig("connection", "phase") == "error"
        raise "ceremony never failed: #{body.inspect}" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end
    end

    # The two seams a member-plane verb reads before it does anything: an
    # adopted workspace and a credential lineage answering a member token.
    # Adopting them through the lineage's own verbs is what lets a unit test
    # reach the create envelope without a Nexus to talk to.
    def inference_request_ready(daemon, token: "member-token", identity: IDENTITY)
      about = Object.new
      about.define_singleton_method(:member_credential) { token }
      # No transport credential: the executor plane's seam raises the
      # SDK's error, which the daemon reads as "no inbox yet".
      about.define_singleton_method(:executor_credential) do
        raise CybrosAgent::Error, "this fixture holds no transport credential"
      end
      # And no runner lineage: the composite's shape, answered
      # the way an agent-only holder answers it.
      about.define_singleton_method(:runner_credential) do
        raise CybrosAgent::Credentials::PlaneUnavailable, "this fixture holds no runner credential"
      end
      about.define_singleton_method(:lineages) { [] }
      about.define_singleton_method(:runner?) { false }
      about.define_singleton_method(:runner) { nil }
      about.define_singleton_method(:agent?) { true }
      # A fixture lineage is not a connection: the boot-time maintenance worker
      # would only try to renew an object that cannot rotate, so it is ended
      # before the adoption wakes it.
      daemon.lineage.stop_maintenance
      daemon.lineage.adopt(identity: identity, credentials: about)
      daemon.lineage.commit_workspace(about, adopted_workspace)
      daemon
    end

    def adopted_workspace = Rho::Daemon::Lineage::Workspace.adopted(public_id: "ws-1", name: "W")

    # A run fixture answers what the lineage and the lanes ask of one.
    def fake_run(public_id, host: false)
      run = Object.new
      run.define_singleton_method(:public_id) { public_id }
      run.define_singleton_method(:host?) { host }
      run.define_singleton_method(:inference_request?) { !host }
      run.define_singleton_method(:backs?) { |id| host && id == public_id }
      run.define_singleton_method(:child?) { |_id| false }
      run.define_singleton_method(:realtime) { nil }
      run.define_singleton_method(:stop) { nil }
      run
    end

    # The member plane a run verb needs, answering the one token the fake
    # plane accepts, over the transport the test scripted.
    def member_ready(daemon, api, identity: IDENTITY)
      inference_request_ready(daemon, token: NexusDoubles::MEMBER_TOKEN, identity: identity)
      daemon.wire.api_transport = api
      if identity.runner_executor_public_id
        api.stock_runner_unless_present(identity.runner_executor_public_id, tools: daemon.context.registry.serving(:runner).announcement)
      end
      daemon
    end

    # The follower a create starts would poll the fake transport forever;
    # the reactor door is stubbed on the facade to keep each spawn, and
    # restored after.
    def capturing_spawns(daemon)
      spawned = []
      context = daemon.context
      context.define_singleton_method(:spawn) { |&block| spawned << block }
      yield spawned
    ensure
      context&.singleton_class&.remove_method(:spawn)
    end

    # AGENT MODE, for a boot that loads no runner tool: full
    # mode with an empty runner registry refuses to boot, so a test naming
    # a narrower set without one says which mode it means.
    def agent_mode(settings = {})
      Rho::Config.from_hash({ "mode" => "agent" }.merge(settings))
    end

    def runner_mode(settings = {})
      Rho::Config.from_hash({ "mode" => "runner" }.merge(settings))
    end

    def get(daemon, path)
      Net::HTTP.get_response(URI.join(daemon.endpoint, path))
    end

    # THE REGISTERED HANDLER, behind the one guard: what a request meets on
    # the wire, minus the socket. A token makes it an authorized request.
    def route(daemon, method, path) = daemon.routes.table.fetch([method, path])

    # A GET carries its arguments in the path, which is all `ControlServer.query`
    # ever reads.
    def query_request(path, token: nil)
      headers = token ? { "authorization" => ["Bearer #{token}"] } : {}
      request = Object.new
      request.define_singleton_method(:path) { path }
      request.define_singleton_method(:headers) { headers }
      request
    end

    def json_request(hash, content_type: "application/json", token: nil)
      body = StringIO.new(JSON.generate(hash))
      headers = { "content-type" => [content_type].compact }
      headers["authorization"] = ["Bearer #{token}"] if token
      request = Object.new
      request.define_singleton_method(:body) { body }
      request.define_singleton_method(:headers) { headers }
      request
    end

    def inference_request_body = { "model" => "dev/mock-text", "input" => "hi", "idempotency_key" => "k-1" }

    # The one-shot lane's follower, through the context's one door — what
    # `POST /inference_requests` does after the create returned.
    def adopt_inference_request(daemon, about, lane, public_id, body)
      Rho::Extensions::Ops::InferenceRequests.adopt(daemon.context, about, lane, public_id, body)
    end

    def await_daemon_stopping(daemon)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until daemon.lineage.stopping?
        raise "daemon never began stopping" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.01
      end
    end

    def await_workspace_state(daemon, state, token:, timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        body = JSON.parse(request(daemon, :get, "/status", token: token).body)
        workspace = body["workspace"]
        return body if workspace && workspace["state"] == state
        raise "workspace still #{workspace.inspect} after #{timeout}s" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end
    end

    def connect(daemon)
      token = bearer(daemon)
      request(daemon, :post, "/device/start", token: token)
      await_state(daemon, "active", token: token)
      token
    end

    def await_connection_phase(daemon, phase, token:, timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        body = JSON.parse(request(daemon, :get, "/status", token: token).body)
        return body if body.dig("connection", "phase") == phase
        raise "connection still #{body.dig("connection", "phase")} after #{timeout}s (#{body.inspect})" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end
    end

    def await_authority(daemon, signed, token:, timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        body = JSON.parse(request(daemon, :get, "/status", token: token).body)
        return body if body.dig("authority", "signed") == signed
        raise "authority still #{body.dig("authority", "signed")} after #{timeout}s (#{body.inspect})" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end
    end

    def wait_for(seconds = 3)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      until yield
        flunk "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.02
      end
    end

    def console_bundle(name = "console-bundle")
      bundle = File.join(@root, name)
      FileUtils.mkdir_p(bundle)
      File.write(File.join(bundle, "index.html"), "<!doctype html><p>rho</p>")
      bundle
    end

    # An Agent API that refuses the bootstrap read — so the ceremony is won and
    # the filing fails, which is the state staging exists for — until it is
    # healed, standing in for the transient blip that caused it.
    class HealableApi
      def initialize = @healthy = false
      def heal = @healthy = true

      def call(path, method: :get, credential: nil, body: nil, params: nil, headers: {}, timeout:)
        if @healthy
          return NexusDoubles::FakeAgentApi.new.call(
            path, method: method, credential: credential,
            body: body, params: params, headers: headers, timeout: timeout
          )
        end

        CybrosAgent::Response.new(status: 500, headers: {}, body: nil)
      end
    end
  end
end
