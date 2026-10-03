require "test_helper"

class AcpRecoveryTest < Minitest::Test
  Methods = Rho::Acp::Methods

  class RetryCore < RhoAcpTest::CoreDouble
    attr_accessor :replacement

    def retry(public_id, task_key = nil)
      super
      rows["cnv_1"] = replacement
    end
  end

  class InterruptedHistoryCore < RetryCore
    attr_accessor :pages

    def turns(public_id, after_position: nil, limit: nil)
      record(:turns, public_id, after_position: after_position, limit: limit)
      if after_position && !@failed
        @failed = true
        raise Rho::Core::Refused.new("history temporarily unavailable", code: "unavailable", status: 503)
      end
      @pages.fetch(after_position)
    end
  end

  def setup
    @core = RetryCore.new
    @harness = RhoAcpTest::AgentHarness.new(core: @core)
    @harness.initialize_agent
  end

  def teardown
    @harness.close
  end

  def test_retry_rejoins_a_shorter_replacement_under_a_new_message_id
    assert_retry_replacement("a discarded model attempt", "done")
  end

  def test_retry_rejoins_a_same_length_replacement_under_a_new_message_id
    assert_retry_replacement("wrong", "right")
  end

  def test_retry_rejoins_an_empty_snapshot_before_the_new_deltas
    @harness.new_session(cwd: Dir.pwd)
    prepare_retry("")
    @core.replacement = snapshot("").merge("status" => "running", "loop_status" => "running")
    @core.events["cnv_1"] = [
      [["snapshot", snapshot("wrong")], ["turn_status", {
        "turn_public_id" => "trn_1", "agent_loop_public_id" => "alp_1",
        "status" => "failed", "loop_status" => "needs_attention",
      }]],
      [["snapshot", @core.replacement], ["text_delta", { "text" => "done" }], ["turn_status", {
        "turn_public_id" => "trn_1", "agent_loop_public_id" => "alp_1",
        "status" => "completed", "loop_status" => "completed",
      }], ["closed", {}]],
    ]
    error = @harness.refused(Methods::SESSION_PROMPT,
      { "sessionId" => "cnv_1", "prompt" => [{ "type" => "text", "text" => "go" }] })
    assert_equal true, error.data["hold"]

    assert_equal "end_turn", retry_prompt["stopReason"]
    assert_equal %w[wrong done], chunks.map { |u| u.dig("update", "content", "text") }
    assert_equal %w[trn_1:0 trn_1:1], chunks.map { |u| u.dig("update", "messageId") }
  end

  def test_loading_a_failed_turn_recovers_its_retry_target
    assert_loaded_retry(Methods::SESSION_LOAD)
  end

  def test_resuming_a_failed_turn_recovers_its_retry_target_without_history_replay
    assert_loaded_retry(Methods::SESSION_RESUME)
    refute @core.called?(:turns)
  end

  def test_attaching_a_forgotten_failed_turn_recovers_the_returned_runs_retry_target
    prepare_retry("done")
    @core.attach_answer = { "conversation" => { "public_id" => "cnv_1" }, "run" => held_row }
    @harness.request(Methods::SESSION_LOAD, load_params)

    assert_equal "end_turn", retry_prompt["stopReason"]
    assert_equal ["alp_1"], @core.calls_of(:retry).last.first.compact
    assert_equal "done", chunks.last.dig("update", "content", "text")
  end

  def test_answering_a_held_ask_keeps_a_replacement_snapshot_after_a_missed_reset
    @harness.new_session(cwd: Dir.pwd)
    prepare_retry("done")
    @core.rows["cnv_1"] = @core.replacement
    @core.tasks[["alp_1", "a1"]] = { "kind" => "ask", "prompt" => "Which branch?" }
    @core.events["cnv_1"].unshift([
      ["snapshot", snapshot("an earlier round")],
      ["attention_required", { "reason" => "awaiting_human", "blocked_task_keys" => ["a1"] }],
    ])

    assert_equal "end_turn", @harness.prompt("cnv_1", "go")["stopReason"]
    assert_equal "end_turn", @harness.prompt("cnv_1", "main")["stopReason"]
    assert_equal ["an earlier round", "Which branch?", "done"],
      chunks.map { |u| u.dig("update", "content", "text") }
    assert_equal %w[trn_1:0 trn_1:0 trn_1:1], chunks.map { |u| u.dig("update", "messageId") }
    assert_equal [[["alp_1", "a1", "main"], {}]], @core.calls_of(:answer)
  end

  def test_lazy_recovery_pages_past_summary_turns_without_replaying_content
    @core.rows["cnv_1"] = { "status" => "pending" }
    @core.turns_pages = [
      { "turns" => [reply("trn_1", "alp_1")], "pagination" => { "has_more" => true, "after_position" => 1 } },
      { "turns" => [reply("trn_summary", "alp_summary").merge("kind" => "compaction_summary")],
        "pagination" => { "has_more" => false } },
    ]
    @harness.request(Methods::SESSION_RESUME, load_params)
    refute @core.called?(:turns)

    assert_equal "end_turn", @harness.prompt("cnv_1", "/abandon")["stopReason"]
    assert_equal [[["alp_1"], {}]], @core.calls_of(:abandon)
    assert_equal [nil, 1], @core.calls_of(:turns).map { |_, kwargs| kwargs[:after_position] }
    assert_empty chunks
    refute @core.called?(:transcript)
  end

  def test_a_later_loopless_reply_clears_an_older_loop_target
    @core.rows["cnv_1"] = held_row
    @core.turns_pages = [{ "turns" => [reply("trn_1", "alp_1"), reply("trn_2", nil)],
      "pagination" => { "has_more" => false } }]
    @harness.request(Methods::SESSION_LOAD, load_params)

    error = @harness.refused(Methods::SESSION_PROMPT,
      { "sessionId" => "cnv_1", "prompt" => [{ "type" => "text", "text" => "/abandon" }] })
    assert_equal "no turn to abandon on cnv_1", error.message
    refute @core.called?(:abandon)
    assert_equal "trn_2", @harness.agent.sessions["cnv_1"].last_turn
    assert_nil @harness.agent.sessions["cnv_1"].last_loop
    assert_equal 1, @core.calls_of(:turns).length, "a known loopless reply is not a missing target"
  end

  def test_a_failed_target_scan_does_not_publish_a_reply_from_an_earlier_page
    @harness.close
    @core = InterruptedHistoryCore.new
    @core.rows["cnv_1"] = { "status" => "pending" }
    @core.pages = {
      nil => { "turns" => [reply("trn_1", "alp_1")], "pagination" => { "has_more" => true, "after_position" => 1 } },
      1 => { "turns" => [reply("trn_2", "alp_2")], "pagination" => { "has_more" => false } },
    }
    @harness = RhoAcpTest::AgentHarness.new(core: @core)
    @harness.initialize_agent
    @harness.request(Methods::SESSION_RESUME, load_params)

    error = @harness.refused(Methods::SESSION_PROMPT,
      { "sessionId" => "cnv_1", "prompt" => [{ "type" => "text", "text" => "/abandon" }] })
    assert_equal "history temporarily unavailable", error.message
    assert_nil @harness.agent.sessions["cnv_1"].last_turn
    assert_nil @harness.agent.sessions["cnv_1"].last_loop
    refute @core.called?(:abandon)

    assert_equal "end_turn", @harness.prompt("cnv_1", "/abandon")["stopReason"]
    assert_equal [[["alp_2"], {}]], @core.calls_of(:abandon)
    assert_equal [nil, 1, nil, 1], @core.calls_of(:turns).map { |_, kwargs| kwargs[:after_position] }
  end

  private

    def assert_retry_replacement(previous, replacement)
      @harness.new_session(cwd: Dir.pwd)
      prepare_retry(replacement)
      @core.events["cnv_1"].unshift([
        ["snapshot", snapshot(previous)],
        ["turn_status", { "turn_public_id" => "trn_1", "agent_loop_public_id" => "alp_1",
          "status" => "failed", "loop_status" => "needs_attention", "failure_reason" => "provider failed" }],
      ])
      @core.rows["cnv_1"] = held_row

      error = @harness.refused(Methods::SESSION_PROMPT,
        { "sessionId" => "cnv_1", "prompt" => [{ "type" => "text", "text" => "go" }] })
      assert_equal true, error.data["hold"]
      before = chunks.length
      previous_id = chunks.last.dig("update", "messageId")

      assert_equal "end_turn", retry_prompt["stopReason"]
      fresh = chunks.drop(before)
      assert_equal replacement, fresh.map { |u| u.dig("update", "content", "text") }.join
      assert_equal ["trn_1:1"], fresh.map { |u| u.dig("update", "messageId") }.uniq
      refute_equal previous_id, fresh.first.dig("update", "messageId")
    end

    def assert_loaded_retry(method)
      prepare_retry("done")
      @core.rows["cnv_1"] = held_row
      @core.turns_pages = [{ "turns" => [{ "public_id" => "trn_1", "role" => "assistant",
        "kind" => "direct_reply", "status" => "failed", "active_variant" => {
          "agent_loop_public_id" => "alp_1", "content" => "", "prompt_text" => "go",
        } }], "pagination" => { "has_more" => false } }]
      @harness.request(method, load_params)

      assert_equal "end_turn", retry_prompt["stopReason"]
      assert_equal ["alp_1"], @core.calls_of(:retry).last.first.compact
      assert_equal "done", chunks.last.dig("update", "content", "text")
    end

    def retry_prompt
      @harness.prompt("cnv_1", "/retry")
    rescue Rho::Acp::RemoteError => error
      flunk("the held turn must remain retryable: #{error.message}")
    end

    def prepare_retry(text)
      @core.replacement = snapshot(text).merge("complete" => true, "status" => "completed", "loop_status" => "completed")
      @core.events["cnv_1"] = [[["snapshot", @core.replacement], ["closed", {}]]]
    end

    def snapshot(text)
      accumulator = CybrosAgent::Api::TranscriptAccumulator.new
      accumulator.accumulate(text, key: "r1")
      { "turn" => "trn_1", "loop" => "alp_1", "text" => accumulator.text, "text_length" => accumulator.length }
    end

    def held_row = { "turn" => "trn_1", "loop" => "alp_1", "status" => "failed", "loop_status" => "needs_attention" }
    def load_params = { "sessionId" => "cnv_1", "cwd" => Dir.pwd, "mcpServers" => [] }
    def chunks = @harness.updates_of("agent_message_chunk")

    def reply(turn, loop_id)
      { "public_id" => turn, "kind" => "direct_reply", "role" => "assistant",
        "active_variant" => { "content" => "", "agent_loop_public_id" => loop_id } }
    end
end
