require "test_helper"
require_relative "../support/materialization_core"
require_relative "../../../rho/test/support/ops_harness"

class AcpFollowCatchUpTest < Minitest::Test
  include RhoTest::OpsHarness

  class Core < RhoAcpTest::MaterializationCore
    attr_accessor :remote, :after_first_follow, :after_approval
    attr_reader :frames

    def initialize(**)
      super
      @frames = []
    end

    def loop_events(id, deadline: nil)
      record(:loop_events, id, deadline: deadline)
      @remote.loop_events(id, deadline: deadline) do |type, payload|
        @frames << [type, payload]
        yield type, payload
      end
    ensure
      @after_first_follow.call if calls_of(:loop_events).length == 1
    end

    def loop_row(...) = @remote.loop_row(...)

    def approve(...)
      super
      @after_approval.call
    end
  end

  def teardown
    @harness&.close
    super
  end

  def test_a_follow_closed_by_the_prior_turn_rejoins_and_delivers_the_current_permission
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new)
    api = CybrosAgent::Client.new(base_url: "https://nexus.example", credential: NexusDoubles::MEMBER_TOKEN,
      transport: NexusDoubles::FakeAgentApi.new)
    run = Rho::HostRun.new(host: Rho::Host::Conversation.new(public_id: "cnv_1"),
      context: api.workspace("ws-1").conversations.conversation("cnv_1"), stream: false)
    daemon.lineage.install_run(daemon.lineage.credentials, run)
    project(run, "turn_status", "turn_public_id" => "trn_prior", "agent_loop_public_id" => "alp_prior",
      "status" => "completed", "loop_status" => "completed")
    core = Core.new
    core.remote = Rho::Core.new(home: daemon.home)
    core.say_answers << { "turn" => { "public_id" => "trn_editor" }, "loop" => { "public_id" => "alp_editor" } }
    core.publish("turn_status", turn_public_id: "trn_editor", agent_loop_public_id: "alp_editor", status: "running")
    core.tasks[["alp_editor", "call"]] = { "tool_name" => "bash", "tool_input" => { "command" => "ls" } }
    target = { "turn_public_id" => "trn_editor", "agent_loop_public_id" => "alp_editor" }
    # The receipt can read Nexus before the independent daemon follower.
    # Let the real HTTP follow close on the old terminal snapshot first.
    core.after_first_follow = lambda do
      project(run, "turn_status", target.merge("status" => "running", "loop_status" => "running"))
      project(run, "task_status", target.merge("task_key" => "call", "kind" => "tool_task", "status" => "needs_approval"))
      project(run, "attention_required", target.merge("reason" => "approval_required", "blocked_task_keys" => ["call"]))
    end
    core.after_approval = -> { project(run, "turn_status", target.merge("status" => "completed", "loop_status" => "completed")) }
    @harness = RhoAcpTest::AgentHarness.new(core: core, home: daemon.home, mode: "ask")
    @harness.policy = RhoAcpTest.permission_policy("allow")
    @harness.initialize_agent
    @harness.new_session(cwd: @root)

    answer = @harness.prompt("cnv_1", "look around")

    assert_equal "end_turn", answer.fetch("stopReason")
    assert_equal 2, core.calls_of(:loop_events).length
    assert_equal %w[snapshot closed], core.frames.first(2).map(&:first)
    assert_equal "trn_prior", core.frames.first.last.fetch("turn")
    assert_equal "turn_settled", core.frames[1].last.fetch("reason")
    assert_equal [[["alp_editor", "call"], {}]], core.calls_of(:approve)
  end

  private

    def project(run, type, payload)
      @sequence = (@sequence || 0) + 1
      event = CybrosAgent::Api::ConversationEvent.new(public_id: "event-#{@sequence}", sequence: @sequence,
        cursor: "cursor-#{@sequence}", type: type, resource_type: "conversation", resource_public_id: "cnv_1",
        occurred_at: "2026-09-22T00:00:00Z", payload: payload)
      run.send(:apply, event)
    end
end
