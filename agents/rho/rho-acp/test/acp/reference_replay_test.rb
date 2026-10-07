require "test_helper"

class AcpReferenceReplayTest < Minitest::Test
  Methods = Rho::Acp::Methods

  def setup
    @core = RhoAcpTest::CoreDouble.new
    @core.rows["cnv_side"] = { "status" => "pending" }
    @harness = RhoAcpTest::AgentHarness.new(core: @core)
    @harness.initialize_agent
  end

  def teardown
    @harness.close
  end

  def test_a_reference_only_side_replays_one_context_chunk_without_an_answer_or_execution_target
    @core.turns_pages = [page(reference)]

    load_session

    chunks = @harness.updates_of("user_message_chunk")
    assert_equal 1, chunks.length
    assert_equal "trn_reference:reference", chunks.first.dig("update", "messageId")
    assert_equal "Parent conversation reference snapshot (context only):\n\n#{reference.dig("active_variant", "content")}",
      chunks.first.dig("update", "content", "text")
    assert_empty @harness.updates_of("agent_message_chunk")
    assert_empty @harness.updates_of("tool_call")
    refute @core.called?(:transcript)
    assert_nil session.last_turn
    assert_nil session.last_variant
    assert_nil session.last_loop
  end

  def test_lazy_target_recovery_never_adopts_an_inherited_parent_run_or_reference
    @core.turns_pages = [page(inherited, reference)]
    @harness.request(Methods::SESSION_RESUME, load_params)

    error = @harness.refused(Methods::SESSION_PROMPT,
      { "sessionId" => "cnv_side", "prompt" => [{ "type" => "text", "text" => "/abandon" }] })

    assert_equal "no turn to abandon on cnv_side", error.message
    refute @core.called?(:abandon)
    refute @core.called?(:transcript)
    assert_empty @harness.updates_of("user_message_chunk")
    assert_empty @harness.updates_of("agent_message_chunk")
    assert_nil session.last_turn
    assert_nil session.last_loop
  end

  def test_a_later_owned_reply_remains_actionable_and_inherited_history_remains_readable
    @core.turns_pages = [
      page(inherited, reference, more: true),
      page({ "public_id" => "trn_side", "kind" => "direct_reply", "role" => "assistant",
        "status" => "failed", "active_variant" => {
          "public_id" => "variant_side", "prompt_text" => "the side question",
          "content" => "the side's partial answer", "run_public_id" => "alp_side",
        } }),
    ]
    @core.transcripts["alp_parent"] = { "rounds" => [], "has_older" => false }
    @core.transcripts["alp_side"] = { "rounds" => [], "has_older" => false }

    load_session

    assert_equal ["the settled parent answer", "the side's partial answer"],
      @harness.updates_of("agent_message_chunk").map { |chunk| chunk.dig("update", "content", "text") }
    assert_equal ["trn_side", "variant_side", "alp_side"],
      [session.last_turn, session.last_variant, session.last_loop]
    assert_equal "end_turn", @harness.prompt("cnv_side", "/abandon")["stopReason"]
    assert_equal [[["alp_side"], {}]], @core.calls_of(:abandon)
  end

  private

    def load_params = { "sessionId" => "cnv_side", "cwd" => Dir.pwd, "mcpServers" => [] }
    def load_session = @harness.request(Methods::SESSION_LOAD, load_params)
    def session = @harness.agent.sessions["cnv_side"]

    def page(*turns, more: false)
      { "turns" => turns, "pagination" => { "has_more" => more, "after_position" => 2 } }
    end

    def reference
      { "public_id" => "trn_reference", "kind" => "direct_reply", "role" => "assistant",
        "status" => "completed", "reference" => true, "inherited" => false,
        "active_variant" => { "public_id" => "variant_reference", "prompt_text" => "the parent question",
          "content" => "User:\nthe parent question\n\nAssistant:\nPersisted parent work; the parent still owns its execution." } }
    end

    def inherited
      { "public_id" => "trn_parent", "kind" => "direct_reply", "role" => "assistant",
        "status" => "completed", "inherited" => true,
        "active_variant" => { "public_id" => "variant_parent", "prompt_text" => "the earlier parent question",
          "content" => "the settled parent answer", "run_public_id" => "alp_parent" } }
    end
end
