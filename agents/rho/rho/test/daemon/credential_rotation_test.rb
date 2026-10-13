require "test_helper"
require "cybros_agent/test_support/fake_realtime"

class DaemonCredentialRotationTest < Minitest::Test
  include RhoTest::DaemonHarness

  # Refresh leaves earlier access tokens usable until their own expiry.
  # Keep each issued token's plane and clock, instead of returning the same
  # token on every rotation as the ordinary OAuth fixture does.
  class OAuth < NexusDoubles::FakeOAuth
    def initialize(clock:)
      super()
      @clock = clock
      @issued = {}
      @sequence = 0
    end

    def post(path, params, timeout:)
      response = super
      return response unless path == "/oauth/token" && response.status == 200

      @sequence += 1
      body = response.body.dup
      body["access_token"] = issue(body.fetch("access_token"), body.fetch("expires_in"))
      if body["executor_access_token"]
        body["executor_access_token"] = issue(body.fetch("executor_access_token"), body.fetch("expires_in"))
      end
      if body["runner"]
        body["runner"] = body.fetch("runner").merge(
          "access_token" => issue(NexusDoubles::RUNNER_TOKEN, body.fetch("expires_in"))
        )
      end
      respond(200, body)
    end

    def plane(credential)
      token, expiry = @issued.fetch(credential)
      token if @clock.call < expiry
    end

    private

      def issue(plane, lifetime)
        token = "#{plane}.issued-#{@sequence}"
        @issued[token] = [plane, @clock.call + lifetime]
        token
      end
  end

  class Api
    attr_accessor :events

    def initialize(oauth)
      @oauth = oauth
      @events = []
      @api = NexusDoubles::FakeAgentApi.new(conversation_events: -> { @events })
    end

    def call(path, credential:, **options)
      plane = @oauth.plane(credential)
      unless plane
        return CybrosAgent::Response.new(status: 401, headers: {},
          body: { "error" => { "code" => "unauthorized", "message" => "Unauthorized" } })
      end

      @api.call(path, credential: plane, **options)
    end

    def stock_inbox(row) = @api.stock_inbox(row, address: :runner)
    def commits = @api.commits
  end

  class Realtime < CybrosAgent::TestSupport::FakeRealtime
    def rebind
      close
      true
    end
  end

  def test_installed_runners_keep_polling_after_their_original_access_tokens_expire
    daemon, = connected
    about = daemon.lineage.credentials
    runners = daemon.lineage.runners
    assert_equal 2, runners.length

    rotate_then_expire_original_access(daemon)
    assert_equal({ member: :live, executor_transport: :live, runner_transport: :live },
      daemon.maintenance.authority_snapshot.report.fetch(:planes))
    runners.each { |runner| runner.send(:sweep) }

    assert runners.all? { |runner| runner.snapshot.running },
      "normal refresh must keep both existing executor runtimes polling with their current access token"
    assert_equal runners, daemon.lineage.runners, "refresh does not replace runtimes or interrupt tools"
    assert_same about, daemon.lineage.credentials
  end

  def test_an_existing_conversation_replays_after_its_original_member_token_expires
    daemon, api = connected
    run = open_host(daemon)

    rotate_then_expire_original_access(daemon)
    api.events = [ended(run.public_id)]
    failure = begin
      run.follow
      nil
    rescue CybrosAgent::Api::Unauthorized => error
      error.class.name
    end

    assert_nil failure, "the already-installed SDK feed must replay with the renewed member credential"
    assert_equal 1, run.snapshot.sequence
    assert_nil host_store(daemon).find(run.public_id), "the replayed terminal event forgets the host"
  end

  def test_a_tool_claimed_before_rotation_commits_with_the_same_renewed_runner_lineage
    daemon, api = connected
    runner = daemon.lineage.runner
    release = File.join(@root, "release-before-rotation")
    api.stock_inbox({ "kind" => "tool_call", "run_public_id" => "other-profile-run",
      "conversation_public_id" => nil, "parent_public_id" => nil, "task_key" => "t1",
      "tool_name" => "bash", "tool_input" => { "command" => "while [ ! -e #{release} ]; do sleep 0.01; done; echo finished" },
      "tool_call_id" => "call-t1", "started_at" => "2026-09-19T00:00:00Z", "deadline_at" => nil, "claimed" => false,
      "addressed_to" => { "role" => "runner", "executor_public_id" => "0199-runner" } })
    daemon.context.spawn { runner.nudged(run_public_id: "other-profile-run", task_key: "t1", tool_name: "bash") }
    wait_for { runner.snapshot.in_flight == 1 }

    rotate_then_expire_original_access(daemon)
    assert_same runner, daemon.lineage.runner
    assert_equal 1, runner.snapshot.in_flight, "a credential refresh does not cancel the tool"
    File.write(release, "go")
    wait_for { !api.commits.empty? }

    assert_equal 1, api.commits.length
    assert_equal "completed", api.commits.first.last.fetch("outcome")
    assert_includes api.commits.first.last.fetch("content"), "finished"
  ensure
    File.write(release, "go") if release && File.directory?(File.dirname(release))
  end

  def test_a_readopted_conversation_uses_its_restored_credential_owner_after_rotation
    daemon, api, oauth = connected
    public_id = open_host(daemon).public_id
    daemon.stop
    restarted = boot_connection(oauth, api)
    wait_for { restarted.lineage.follower(public_id) && restarted.lineage.runners.length == 2 }
    restarted.maintenance.stop
    run = restarted.lineage.follower(public_id)

    rotate_then_expire_original_access(restarted)
    api.events = [ended(public_id)]
    wait_for { host_store(restarted).find(public_id).nil? }

    assert_equal 1, run.snapshot.sequence, "the restored feed consumes the terminal row after the original token expires"
  end

  private

    def connected
      @now = Time.now
      oauth = OAuth.new(clock: -> { @now })
      api = Api.new(oauth)
      daemon = boot_connection(oauth, api)
      token = connect(daemon)
      await_workspace_state(daemon, "adopted", token: token)
      wait_for { daemon.lineage.runners.length == 2 }
      daemon.maintenance.stop
      [daemon, api, oauth]
    end

    def boot_connection(oauth, api)
      boot(device_flow: connection_device_flow(oauth), api_transport: api,
        clock: -> { @now }, config: Rho::Config.from_hash({ "executor_socket" => false }),
        realtime_factory: ->(*) { Realtime.new })
    end

    def open_host(daemon)
      capturing_spawns(daemon) do
        status, body = route(daemon, "POST", "/conversations").call(
          json_request({ "live" => false }, token: bearer(daemon))
        )
        assert_equal 201, status
        run = daemon.lineage.follower(body.fetch(:conversation).fetch(:public_id))
        refute_nil run
        run
      end
    end


    def ended(public_id)
      { "public_id" => "e-ended", "sequence" => 1, "cursor" => "c1", "type" => "conversation_ended", "payload" => {},
        "resource" => { "type" => "conversation", "public_id" => public_id }, "occurred_at" => "2026-09-19T00:00:00Z" }
    end

    def rotate_then_expire_original_access(daemon)
      @now += 8 * 24 * 60 * 60
      assert_equal [:renewed, :renewed], daemon.maintenance.run_once(daemon.lineage.credentials, verify: false)
      @now += 7 * 24 * 60 * 60
    end
end
