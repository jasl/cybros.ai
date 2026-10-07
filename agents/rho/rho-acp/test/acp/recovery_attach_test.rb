require "test_helper"
require_relative "../../../rho/test/support/ops_harness"

class AcpRecoveryAttachTest < Minitest::Test
  include RhoTest::OpsHarness

  Methods = Rho::Acp::Methods

  class AttachedCore < RhoAcpTest::CoreDouble
    attr_accessor :remote
    attr_reader :attached

    def attach(...) = @attached = @remote.attach(...)
    def follower_row(...) = @remote.follower_row(...)
    def turns(...) = @remote.turns(...)
  end

  def teardown
    @harness&.close
    super
  end

  def test_load_recovers_the_held_target_before_the_fresh_daemon_follower_replays
    assert_recovery(Methods::SESSION_LOAD)
  end

  def test_resume_recovers_the_held_target_only_when_a_command_needs_it
    assert_recovery(Methods::SESSION_RESUME)
  end

  private

    def assert_recovery(method)
      api = NexusDoubles::FakeAgentApi.new(turns: [
        { "public_id" => "trn_1", "position" => 1, "kind" => "direct_reply", "role" => "assistant",
          "answering_user_public_id" => "usr_1", "status" => "failed", "visibility" => "visible", "created_at" => "2026-09-20T00:00:00Z",
          "active_variant" => { "public_id" => "var_1", "source" => "run", "status" => "failed",
            "run_public_id" => "alp_1", "content" => "", "prompt_text" => "go" } },
      ])
      daemon = member_ready(boot, api)
      core = AttachedCore.new
      core.remote = Rho::Core.new(home: daemon.home)
      @harness = RhoAcpTest::AgentHarness.new(core: core, home: daemon.home)
      @harness.initialize_agent

      capturing_spawns(daemon) do |spawned|
        @harness.request(method, { "sessionId" => "c-1", "cwd" => @root, "mcpServers" => [] })
        refute_empty spawned, "the actual daemon follower is waiting to start its replay"
        assert_nil core.attached.dig("run", "turn")
        assert_nil core.attached.dig("run", "run_public_id")
        assert_nil core.follower_row("c-1")["turn"]
        assert_empty @harness.updates_of("user_message_chunk") if method == Methods::SESSION_RESUME

        answer = begin
          @harness.prompt("c-1", "/abandon")
        rescue Rho::Acp::RemoteError => error
          flunk("the durable held turn must be available: #{error.message}")
        end
        assert_equal "end_turn", answer["stopReason"]
        assert_equal "var_1", @harness.agent.sessions["c-1"].last_variant
        assert_equal [[["alp_1"], {}]], core.calls_of(:abandon)
      end
    end
end
