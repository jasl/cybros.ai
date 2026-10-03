require "test_helper"
require_relative "../support/materialization_core"

class AcpMaterializationTest < Minitest::Test
  Methods = Rho::Acp::Methods

  def setup
    @core = RhoAcpTest::MaterializationCore.new
  end

  def teardown
    @harness&.notify(Methods::SESSION_CANCEL, "sessionId" => "cnv_1")
    @harness&.close
  end

  def test_a_pending_prompt_does_not_finish_with_an_earlier_senders_queued_turn
    @core.rows["cnv_1"] = {
      "public_id" => "cnv_1", "turn" => "trn_running", "loop" => "alp_running",
      "status" => "running", "complete" => false,
    }
    # Another sender's input is already ahead of this editor's input. The
    # running turn finishes and that earlier input materializes first.
    @core.say_answers << lambda do |*|
      @core.rows["cnv_1"] = {
        "public_id" => "cnv_1", "turn" => "trn_other", "loop" => "alp_other",
        "turn_kind" => "direct_reply", "status" => "completed", "complete" => true,
      }
      @core.publish("input_materialized", input_public_id: "cin_other", turn_public_id: "trn_other")
      @core.publish("turn_status", turn_public_id: "trn_other", agent_loop_public_id: "alp_other", status: "running")
      @core.pending_receipt
    end
    @core.events["cnv_1"] = [[
      ["snapshot", @core.rows.fetch("cnv_1").merge(
        "turn" => "trn_other", "loop" => "alp_other", "text" => "The other sender's answer"
      )],
      ["turn_status", {
        "turn_public_id" => "trn_other", "agent_loop_public_id" => "alp_other",
        "status" => "completed", "loop_status" => "completed",
      }],
      ["closed", {}],
    ]]
    ready

    pending = @harness.start_prompt("cnv_1", "The editor's later question")

    assert_raises(Rho::Acp::Unanswered,
      "cin_editor is still queued: another sender's completed turn cannot answer this prompt") do
      pending.wait(timeout: 0.5)
    end
    refute_equal "alp_other", @harness.agent.sessions["cnv_1"].last_loop
    refute(@harness.updates.any? do |update|
      update.dig("update", "content", "text") == "The other sender's answer"
    end)
    assert_empty @core.calls_of(:loop_events)

    @core.events["cnv_1"] = [completed_follow("trn_editor", "alp_editor")]
    materialize

    assert_equal "end_turn", pending.wait(timeout: 3).fetch("stopReason")
    assert_equal "trn_editor", @harness.agent.sessions["cnv_1"].last_turn
    assert_equal "alp_editor", @harness.agent.sessions["cnv_1"].last_loop
    assert_equal RhoAcpTest::MaterializationCore::POSITION.fetch("cursor"), @core.calls_of(:host_events).first.last.fetch(:after)
  end

  def test_a_pending_say_waits_past_compaction_for_its_own_input
    @core.say_answers << @core.pending_receipt.merge("compaction" => {
      "turn" => { "public_id" => "trn_summary" }, "loop" => { "public_id" => "alp_summary" },
    })
    @core.publish("turn_status", turn_public_id: "trn_summary", turn_kind: "compaction_summary",
      agent_loop_public_id: "alp_summary", status: "running")
    @core.publish("input_blocked", input_public_id: "cin_other", blocked_reason: "unknown_model")
    @core.rows["cnv_1"] = { "turn" => "trn_summary", "loop" => "alp_summary", "turn_kind" => "compaction_summary" }
    ready

    pending = @harness.start_prompt("cnv_1", "go")
    assert_raises(Rho::Acp::Unanswered) { pending.wait(timeout: 0.2) }
    assert_empty @core.calls_of(:loop_events)

    @core.events["cnv_1"] = [completed_follow("trn_editor", "alp_editor")]
    materialize

    assert_equal "end_turn", pending.wait(timeout: 3).fetch("stopReason")
    assert_equal "alp_editor", @harness.agent.sessions["cnv_1"].last_loop
  end

  def test_the_pending_inputs_own_block_is_reported
    @core.say_answers << @core.pending_receipt
    @core.publish("input_blocked", input_public_id: "cin_editor", blocked_reason: "unknown_model")
    ready

    error = assert_raises(Rho::Acp::RemoteError) { @harness.start_prompt("cnv_1", "go").wait(timeout: 3) }

    assert_equal(-32602, error.code)
    assert_equal "the kernel blocked the input (unknown_model)", error.message
    assert_empty @core.calls_of(:loop_events)
  end

  def test_cancel_ends_the_pending_wait_without_following_the_current_turn
    @core.say_answers << @core.pending_receipt
    @core.rows["cnv_1"] = { "turn" => "trn_other", "loop" => "alp_other" }
    ready

    pending = @harness.start_prompt("cnv_1", "go")
    assert_raises(Rho::Acp::Unanswered) { pending.wait(timeout: 0.2) }
    @harness.notify(Methods::SESSION_CANCEL, "sessionId" => "cnv_1")

    assert_equal "cancelled", pending.wait(timeout: 3).fetch("stopReason")
    assert_equal [[["cnv_1"], { force: true }]], @core.calls_of(:stop)
    assert_empty @core.calls_of(:loop_events)
  end

  def test_a_loopless_direct_reply_is_followed_until_its_turn_completes
    @core.say_answers << @core.pending_receipt
    materialize(loop_id: nil)
    frames = Queue.new
    frames << ["snapshot", { "turn" => "trn_editor", "status" => "running", "complete" => false }]
    @core.events["cnv_1"] = frames
    ready

    pending = @harness.start_prompt("cnv_1", "go")
    assert_raises(Rho::Acp::Unanswered) { pending.wait(timeout: 0.2) }
    completed_follow("trn_editor", nil).each { |frame| frames << frame }
    frames << :closed

    assert_equal "end_turn", pending.wait(timeout: 3).fetch("stopReason")
    assert_equal "trn_editor", @harness.agent.sessions["cnv_1"].last_turn
    assert_nil @harness.agent.sessions["cnv_1"].last_loop
  end

  def test_joining_after_its_turn_completed_recovers_its_answer_without_successor_text_or_approval
    @core.say_answers << @core.pending_receipt
    materialize
    @core.publish("turn_status", turn_public_id: "trn_editor", agent_loop_public_id: "alp_editor",
      status: "completed", loop_status: "completed")
    @core.publish("input_materialized", input_public_id: "cin_successor", turn_public_id: "trn_successor")
    @core.publish("turn_status", turn_public_id: "trn_successor", agent_loop_public_id: "alp_successor", status: "running")
    @core.variant_rows = [{
      "public_id" => "vrn_editor", "active" => true, "agent_loop_public_id" => "alp_editor",
      "status" => "completed", "content" => "The editor's sealed answer",
    }]
    @core.events["cnv_1"] = [[
      ["snapshot", { "turn" => "trn_successor", "loop" => "alp_successor", "text" => "The successor's answer",
                     "status" => "running", "complete" => false,
                     "attention" => { "reason" => "approval_required", "blocked_task_keys" => ["effect"] } }],
      ["text_delta", { "text" => "More successor text" }],
      ["attention_required", { "reason" => "approval_required", "blocked_task_keys" => ["effect"] }],
      ["closed", {}],
    ]]
    ready
    @harness.policy = :hold

    assert_equal "end_turn", @harness.prompt("cnv_1", "go").fetch("stopReason")
    texts = @harness.updates_of(Methods::SessionUpdate::AGENT_MESSAGE_CHUNK).map { |update| update.dig("update", "content", "text") }
    assert_equal ["The editor's sealed answer"], texts
    assert_equal "trn_editor", @harness.agent.sessions["cnv_1"].last_turn
    assert_equal "alp_editor", @harness.agent.sessions["cnv_1"].last_loop
    assert @harness.held.empty?, "a successor's approval must not be offered for this prompt"
    assert_empty @core.calls_of(:task)
    assert_empty @core.calls_of(:approve)
    assert_equal [[["cnv_1", "trn_editor"], {}]], @core.calls_of(:variants)
  end

  private

    def ready
      @harness = RhoAcpTest::AgentHarness.new(core: @core)
      @harness.initialize_agent
      @harness.new_session(cwd: "/tmp")
    end

    def materialize(loop_id: "alp_editor")
      @core.publish("input_materialized", input_public_id: "cin_editor", turn_public_id: "trn_editor")
      @core.publish("turn_status", turn_public_id: "trn_editor", turn_kind: "direct_reply",
        agent_loop_public_id: loop_id, status: "running")
    end

    def completed_follow(turn, loop_id)
      [
        ["snapshot", { "turn" => turn, "loop" => loop_id }],
        ["turn_status", { "turn_public_id" => turn, "agent_loop_public_id" => loop_id,
                          "status" => "completed", "loop_status" => loop_id && "completed" }],
        ["closed", {}],
      ]
    end
end
