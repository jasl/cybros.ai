require "test_helper"
require "test_helpers/log_capture"

# THE ONE FIT: history and the reasoning it carries share the window the kernel plans to, measured in
# the provider's tokens AND in the bytes the request seals, and a history that crosses either with no
# bound the caller stated arms the timeline compaction — never a request the seal refuses, never a
# trace dropped to make room. The answer's own room is the window's margin on every row.
class Conversations::ContextAssemblyFitTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper
  include LogCapture

  Assembly = Conversations::ContextAssembly

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  def converge! = Conversations::Turns::Converge.call

  def windowed_turn!(text, **over)
    post_input!(@conversation, acting_user: @agent, kind: "direct_reply", text: text,
      provider_id: "dev", model_ref: DevModelLane::WINDOWED_TEXT_MODEL.split("/", 2).last, **over)
  end

  # One settled thinking turn: short words, a thought the provider counts at `tokens` under `key`
  # (`reasoning_tokens` on the Responses wires, `thinking_tokens` where Anthropic reports it).
  def thinking_turn!(index, tokens:, key: "reasoning_tokens")
    windowed_turn!("ask #{index}")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    agent_loop = @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("answer #{index}", reasoning: "thinking", reasoning_encrypted: "blob-#{index}",
      usage: { "input_tokens" => 2, "output_tokens" => tokens + 3, "output_tokens_details" => { key => tokens } }))
    converge!
    assert_equal "completed", agent_loop.reload.status
  end

  # A blob-heavy thought: few tokens by the provider's count, many bytes on the wire.
  def heavy_thought(text, blob)
    sse_success(text, reasoning: "thinking", reasoning_encrypted: blob,
      usage: { "input_tokens" => 2, "output_tokens" => 13, "output_tokens_details" => { "reasoning_tokens" => 10 } })
  end

  # Opaque reasoning is ~7 bytes a token against ~4 for text, so on a large window the byte wall
  # binds before the token fit: two turns of blobs the window holds by count would seal a request
  # the storage bound refuses. The fit measures both and arms the summary at whichever crosses.
  test "a blob-heavy history crossing the byte budget before the token fit arms the summary" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      declare_tools!(@agent)
      2.times do |index|
        windowed_turn!("ask #{index}")
        Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
        agent_loop = @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
        schedule_loop!(agent_loop)
        run_loop_round!(agent_loop, heavy_thought("answer #{index}", "b#{index}" * 350_000))
        converge!
        assert_equal "completed", agent_loop.reload.status
      end

      head = windowed_turn!("and now")
      lines = capture_log { Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id) }

      assert_equal "running", @conversation.conversation_turns.find_by!(kind: "compaction_summary").status
      assert_equal "pending", head.reload.state, "the head waits behind the summary, never blocked"
      assert_nil head.blocked_reason
      assert_empty lines.grep(/event=reasoning_replay_dropped/), "no request re-sent without its traces"
    end
  end

  # The trace is priced as the provider bills it: a signed Anthropic block's text is only a summary
  # of the thinking the server counts (`thinking_tokens`), and the fit charges the count.
  test "an Anthropic-shaped trace costs its thinking tokens in the fit, not its summary" do
    envelope = ModelReasoning::TraceBuilder.call(
      result: Data.define(:output_items, :assistant_message, :usage).new(
        output_items: [{ "type" => "reasoning", "text" => "a forty-character summary of a long plan",
                         "signature" => "sig-1" }],
        assistant_message: nil,
        usage: { "output_tokens" => 250, "output_tokens_details" => { "thinking_tokens" => 210 } }
      ),
      origin: { provider_id: "anthropic", model_id: "claude-opus-5-5", api_format: "anthropic_messages",
                invocation_id: "inv" },
      normalized_tool_calls: []
    )
    trace = ModelReasoning::Trace.new(envelope: envelope)
    target = ModelReasoning::ReplayLadder::Target.new(provider_id: "anthropic", model_id: "claude-opus-5-5",
      reasoning_effort: "medium", capability: Nexus::ReasoningReplayCapability.new(format: "anthropic_thinking"))
    profile = DevModelLane.profile_with(DevModelLane.profile_for("dev/mock-text"), token_counter: nil)
    segment = Assembly::Segment.plain("assistant", "done", trace: trace)

    landed, = Assembly::Replayed.decide([segment], replay: Assembly::Replay.new(mode: "all", target: target),
      profile: profile)

    assert_equal 1, landed.sole.reasoning_parts.length, "the signed block rides"
    assert_equal 210, landed.sole.replay_tokens
    assert_equal Assembly::FillCost.call("done", profile) + 210, Assembly::FillCost.segment(landed.sole, profile)
  end

  # A STATED BOUND COUNTS THE TRACES TOO: history and the reasoning it carries share the one fit, so
  # a turn's own `history` share cuts the oldest turn whose words would fit but whose thinking does
  # not — the caller's bound, trimmed as asked, never a trace dropped to keep its words.
  test "a stated history bound prices the traces inside it" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      declare_tools!(@agent)
      thinking_turn!(0, tokens: 3_000)

      windowed_turn!("and now", context_options: { "history" => { "token_budget_share" => 0.25 } })
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      agent_loop = @conversation.conversation_turns.order(:position).last.active_variant.agent_loop
      schedule_loop!(agent_loop)
      sent = round_request_entries(loop_node(agent_loop, "r1")).to_json

      assert_not_includes sent, "ask 0", "2,048 tokens hold the earlier words, never with their 3,000 of thinking"
      assert_not_includes sent, "blob-0"
      assert_equal ["budget_exceeded"], @conversation.conversation_event_items.where(item_type: "context_trimmed")
        .map { |item| item.payload["history_skipped_reason"] }
    end
  end

  # The count the provider bills is the price whichever key it reports: a thought counted as
  # `thinking_tokens` — Anthropic's word — reaches the wall on that count, where its few words alone
  # would fit.
  test "a trace priced by its thinking count reaches the wall its words alone would not" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      declare_tools!(@agent)
      2.times { |index| thinking_turn!(index, tokens: 4_000, key: "thinking_tokens") }

      head = windowed_turn!("and now")
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

      assert_equal "running", @conversation.conversation_turns.find_by!(kind: "compaction_summary").status
      assert_equal "pending", head.reload.state, "the head waits behind the summary"
    end
  end

  # THE ANSWER ROOM: the planning window less `min(32k, 12.5 %)`, on every row — 175k of a 200k
  # shared window, 7,168 of the dev row's 8,192, 967,232 of a 1M window — and nothing under an
  # advisory bound, which already sits below its hard window.
  test "the answer room is the window's margin on every row, and none under an advisory bound" do
    profile = DevModelLane.profile_for("dev/mock-text")
    usable = lambda do |advisory:, hard:|
      Assembly.send(:size, floors: {}, history: {}, profile: profile,
        limits: LimitsOf.bounds(advisory: advisory, hard: hard)).history_budget
    end

    assert_equal 175_000, usable.call(advisory: nil, hard: 200_000)
    assert_equal 7_168, usable.call(advisory: nil, hard: 8_192)
    assert_equal 1_000_000 - 32_768, usable.call(advisory: nil, hard: 1_000_000)
    assert_equal 272_000, usable.call(advisory: 272_000, hard: 1_050_000)
  end
end
