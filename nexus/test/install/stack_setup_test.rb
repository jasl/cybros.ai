require "test_helper"
require_relative "../../../install/stack/setup"

# The installer runs inside the Nexus image and owns this operator flow. Keep
# its regression coverage here so real device grants share the ordinary test DB.
class StackSetupTest < ActiveSupport::TestCase
  Response = Data.define(:status, :body)
  RHO_URL = "http://rho.test:7777".freeze
  SETUP_SECRET = "synthetic setup+secret".freeze
  ENVIRONMENT_KEYS = %w[RHO_SETUP_URL RHO_SETUP_ANNOUNCEMENT RHO_INSTALLATION_FILE BASE_URL NEXUS_SETUP_SECRET].freeze

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
    @directory = Dir.mktmpdir("stack-setup-test-")
    @announcement_path = File.join(@directory, "announcement.json")
    @status_path = File.join(@directory, "installation", "status.json")
    announce("before-restart")
  end

  teardown do
    FileUtils.remove_entry(@directory)
  end

  test "a daemon restart rejoins its new exact grant after a temporary connection refusal" do
    first = issue
    replacement = issue
    foreign = issue
    old_headers = { "authorization" => "Bearer before-restart" }
    new_headers = { "authorization" => "Bearer after-restart" }
    requests = [
      reply("GET", "/status", { mode: "full" }, headers: old_headers),
      reply("POST", "/device/start", { user_code: first.formatted_user_code }, headers: old_headers),
      reply("GET", "/status", headers: old_headers) do
        assert_predicate first.reload, :connected?
        assert_equal @owner, first.connected_by
        assert_predicate foreign.reload, :pending?
        announce("after-restart")
        raise Errno::ECONNREFUSED
      end,
      reply("GET", "/status", { error: { code: "unauthorized" } }, status: 401, headers: old_headers),
      reply("GET", "/status", { mode: "full" }, headers: new_headers),
      reply("POST", "/device/start", { user_code: replacement.formatted_user_code }, headers: new_headers),
      reply("GET", "/status", headers: new_headers) do
        assert_predicate replacement.reload, :connected?
        assert_equal @owner, replacement.connected_by
        consumed = DeviceAuthorizations::Consume.call(authorization: replacement)
        assert_equal :minted, consumed.outcome
        {
          mode: "full",
          authority: { planes: { member: "live", executor_transport: "live", runner_transport: "live" } },
          identity: {
            executor_public_id: consumed.executor_access_token.task_executor.public_id,
            runner_executor_public_id: consumed.runner.executor_access_token.task_executor.public_id,
          },
        }
      end,
    ]

    assert_difference -> { User.count }, 1 do
      assert_difference -> { TaskExecutor.count }, 2 do
        with_rho(requests) { |setup| setup.call }
      end
    end

    assert_predicate first.reload, :connected?
    assert_predicate replacement.reload, :consumed?
    assert_predicate foreign.reload, :pending?
    assert_nil foreign.connected_by
  end

  test "invalid local control credentials fail without connecting a grant and publish an actionable error" do
    grant = issue
    File.write(@announcement_path, "{invalid-private-data")

    assert_no_difference [-> { User.count }, -> { TaskExecutor.count }] do
      with_rho([]) do |setup|
        error = assert_raises(CybrosStackSetup::Error) { setup.call }
        assert_match "local control credentials are invalid", error.message
        assert_equal error.message, installation.fetch("error")
        assert_nil installation.fetch("setup_url")
        refute_includes File.read(@status_path), "invalid-private-data"
      end
    end

    assert_predicate grant.reload, :pending?
    assert_nil grant.connected_by
  end

  test "first boot publishes a private link then clears it before pairing" do
    checks = [false, true]
    requests = [reply("GET", "/status", live_status, headers: { "authorization" => "Bearer before-restart" })]
    observed_wait = false
    on_wait = ->(_seconds) {
      refute installation.fetch("nexus_ready")
      assert_nil installation.fetch("error")
      url = URI(installation.fetch("setup_url"))
      assert_equal "https://nexus.example/base/setup", "#{url.scheme}://#{url.host}#{url.path}"
      assert_equal [["setup_secret", SETUP_SECRET]], URI.decode_www_form(url.fragment)
      assert_equal 0o600, File.stat(@status_path).mode & 0o777
      assert_equal 0o700, File.stat(File.dirname(@status_path)).mode & 0o777
      observed_wait = true
    }

    with_rho(requests, on_wait: on_wait) do |setup|
      Account.stub(:exists?, -> { checks.empty? ? flunk("unexpected readiness query") : checks.shift }) { setup.call }
      assert observed_wait
      assert_equal({ "nexus_ready" => true, "setup_url" => nil, "error" => nil }, installation)
    end
  end

  test "a missing announcement during daemon startup is retried and a stale projection is replaced" do
    File.unlink(@announcement_path)
    FileUtils.mkdir_p(File.dirname(@status_path))
    File.write(@status_path, JSON.generate(nexus_ready: false, setup_url: "stale secret", error: "old error"))
    requests = [reply("GET", "/status", live_status, headers: { "authorization" => "Bearer started" })]

    with_rho(requests, on_wait: ->(_seconds) { announce("started") }) do |setup|
      setup.call
      assert_equal({ "nexus_ready" => true, "setup_url" => nil, "error" => nil }, installation)
    end
  end

  test "automatic setup cannot restore a removed agent registration" do
    member = users(:agent)
    address = task_executors(:address)
    assert_equal :removed, member.remove
    epoch = address.reload.credential_epoch
    grant = issue(agent_identifier: member.agent_identifier)

    assert_manual_reconnect(grant)

    assert_predicate member.reload, :removed?
    assert_equal epoch, address.reload.credential_epoch
  end

  test "automatic setup cannot replace a terminally revoked runner registration" do
    runner = @account.task_executors.create!(
      executor_kind: :runner, display_name: "Bundled runner", runner_identifier: "stack-runner",
      assignment_scope: :user_private, manager: @owner
    )
    assert_equal :revoked, runner.revoke
    epoch = runner.reload.credential_epoch
    grant = issue

    assert_manual_reconnect(grant)

    assert_predicate runner.reload, :revoked?
    assert_equal epoch, runner.credential_epoch
  end

  private

    def announce(bearer)
      File.write(@announcement_path, JSON.generate(bearer: bearer, endpoint: "http://0.0.0.0:7777"), mode: "w", perm: 0o600)
    end

    def installation
      JSON.parse(File.read(@status_path))
    end

    def live_status
      {
        mode: "full",
        authority: { planes: { member: "live", executor_transport: "live", runner_transport: "live" } },
        identity: { executor_public_id: task_executors(:address).public_id, runner_executor_public_id: SecureRandom.uuid_v7 },
      }
    end

    def issue(agent_identifier: "stack-agent", runner_identifier: "stack-runner")
      DeviceAuthorizations::Issue.call(
        account: @account, agent_identifier: agent_identifier, agent_display_name: "Bundled agent",
        requested_executor_display_name: "Bundled agent", runner_identifier: runner_identifier,
        runner_display_name: "Bundled runner"
      ).authorization
    end

    def reply(method, path, document = nil, status: 200, **options, &observe)
      ->(actual_method, actual_url, **actual_options) do
        assert_equal [method, "#{RHO_URL}#{path}"], [actual_method, actual_url]
        assert_equal options, actual_options
        Response.new(status: status, body: JSON.generate(observe ? observe.call : document))
      end
    end

    def with_rho(requests, on_wait: nil)
      previous = ENV.to_h.slice(*ENVIRONMENT_KEYS)
      ENV["RHO_SETUP_URL"] = RHO_URL
      ENV["RHO_SETUP_ANNOUNCEMENT"] = @announcement_path
      ENV["RHO_INSTALLATION_FILE"] = @status_path
      ENV["BASE_URL"] = "https://nexus.example/base/"
      ENV["NEXUS_SETUP_SECRET"] = SETUP_SECRET
      http = HTTPX.with(timeout: { connect_timeout: 5, operation_timeout: 10 })
      request = ->(*arguments, **options) do
        (requests.shift || flunk("unexpected rho request")).call(*arguments, **options)
      end

      HTTPX.stub(:with, http) do
        http.stub(:request, request) do
          setup = CybrosStackSetup.new
          # The HTTP script bounds every retry and rejects any extra request;
          # real sleeps would only slow the same ordered restart sequence.
          output = setup.stub(:sleep, on_wait) { capture_io { yield setup } }
          refute_includes output.join, SETUP_SECRET
          refute_includes output.join, "before-restart"
        end
      end
      assert_empty requests, "setup must finish the expected control exchange"
    ensure
      http&.close
      ENVIRONMENT_KEYS.each { |key| ENV[key] = previous[key] }
    end

    def assert_manual_reconnect(grant)
      announce("existing-installation")
      headers = { "authorization" => "Bearer existing-installation" }
      requests = [
        reply("GET", "/status", { mode: "full" }, headers: headers),
        reply("POST", "/device/start", { user_code: grant.formatted_user_code }, headers: headers),
      ]

      assert_no_difference [-> { User.count }, -> { TaskExecutor.count }] do
        with_rho(requests) do |setup|
          error = assert_raises(CybrosStackSetup::Error) { setup.call }
          assert_match "manual reconnect", error.message
          assert_equal error.message, installation.fetch("error")
          assert installation.fetch("nexus_ready")
          assert_nil installation.fetch("setup_url")
        end
      end

      assert_predicate grant.reload, :pending?
      assert_nil grant.connected_by
    end
end
