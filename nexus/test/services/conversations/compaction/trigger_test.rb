require "test_helper"
require_relative "../../../test_helpers/compaction_test_helper"

# Both hosts arm compaction from the same usage, window and provider-refusal vocabulary.
class Conversations::Compaction::TriggerTest < ActiveJob::TestCase
  include CompactionTestHelper

  # ════════════════════════════════════════════════════════════════════ THE USAGE TRIGGER: the
  # provider's own number, on every lane
  # ════════════════════════════════════════════════════════════════════

  # A request small enough for every counter, on a context the provider says is nearly full: the
  # last reported `input_tokens` plus the tail this round appends crosses the window, and the arm
  # fires BEFORE any count — the provider-reported occupancy takes precedence.
  test "the last reported usage plus the tail arms the repair before any counter" do
    agent_run = loop_at_the_wall(bulk: "the work so far", usage: { "input_tokens" => 9_000, "output_tokens" => 3 })

    schedule!(agent_run)

    round2 = node(agent_run, "round2")
    assert_equal "queued", round2.status, "it waits for its repair"
    assert_equal "k1", round2.compaction["summary_source"], "no results to prune: it summarizes"
    item = compacted_item(agent_run)
    assert_equal "usage", item.payload["trigger"]
    assert_equal "kernel", item.payload["mode"]

    small = loop_at_the_wall(bulk: "the work so far", usage: { "input_tokens" => 100, "output_tokens" => 3 })
    schedule!(small)
    assert_equal "running", node(small, "round2").status, "a hundred tokens arms nothing"
    assert_nil small.agent_run_tasks.find_by(node_key: "k1")
  end

  # THE SOURCE ROUND'S OWN OUTPUT is the next request's input too — its answer and the reasoning it
  # replays — and the provider already counted it as `output_tokens`: occupancy prices the record's
  # input plus its output plus the rest of the tail, the round's own replayed items counted once.
  test "mid-turn occupancy prices the source round's output as its reported output tokens" do
    agent_run = loop_at_the_wall(bulk: "the work so far", usage: { "input_tokens" => 4_500, "output_tokens" => 4_000 })

    schedule!(agent_run)

    assert_equal "queued", node(agent_run, "round2").status, "input plus output crosses the window"
    assert_equal "usage", compacted_item(agent_run).payload["trigger"]
  end

  test "between turns the counted answer's output tokens join the occupancy" do
    build_history!(turns: 2, hex: 40)
    ask_greedily!(text: "first question")
    assert_equal 1, drain!
    settle_reply!("first answer", usage: { "input_tokens" => 4_500, "output_tokens" => 4_000 })

    head = ask_greedily!(text: "second question")
    assert_equal 0, drain!, "the head waits behind the summary"
    assert_equal "pending", head.reload.state
    assert_equal "usage", compacted_item(@conversation).payload["trigger"]
  end

  # Between turns the same reader: a direct reply that reported a nearly
  # full context arms the summary for the NEXT head before it is compiled.
  test "a reply that reported a full context arms the between-turn summary for the next head" do
    build_history!(turns: 2, hex: 40)
    ask_greedily!(text: "first question")
    assert_equal 1, drain!
    settle_reply!("first answer", usage: { "input_tokens" => 9_000, "output_tokens" => 5 })

    head = ask_greedily!(text: "second question")
    assert_equal 0, drain!, "the head waits behind the summary"

    assert_equal "pending", head.reload.state
    turn = summary_turn
    assert_not_nil turn
    assert_equal "running", turn.status
    item = compacted_item(@conversation)
    assert_equal "usage", item.payload["trigger"]
    assert_equal "kernel", item.payload["mode"]
    assert_equal turn.public_id, item.payload["summary_turn_public_id"]
  end

  # THE PRESENTER'S OCCUPANCY reads the same number (Ordering note 5): a
  # loop-backed turn's rounds carry no conversation id, and the console
  # used to show the last DIRECT reply's count instead, silently.
  test "the context report shows a loop-backed turn's last round" do
    conversation, turn, agent_run = run_backed_read!(body: "a small file\n")
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("done", usage: { "input_tokens" => 4_321, "output_tokens" => 7 }))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status

    context = AgentAPI::ConversationPresenter.full(conversation.reload).fetch(:context)

    assert_equal 4_321, context.fetch(:input_tokens)
    assert_equal 8_192, context.fetch(:window_tokens)
    assert_equal "mock-text", context.dig(:as_of_model, :model_ref)
  end

  # SILENT TRUNCATION IS NARRATED, NEVER ACTED ON: a round whose reported input is below its
  # source's by more than the tail it appended could explain is evidence for a console; the kernel
  # picks no threshold and arms nothing on it.
  test "a round reporting fewer input tokens than its source narrates the suspicion and arms nothing" do
    agent_run = loop_at_the_wall(bulk: "the work so far", usage: { "input_tokens" => 5_000, "output_tokens" => 3 })
    schedule!(agent_run)
    assert_equal "running", node(agent_run, "round2").status, "five thousand arms nothing"

    settle!(agent_run, "round2", "and more", usage: { "input_tokens" => 4_000, "output_tokens" => 3 })

    results = agent_run.conversation_event_items.where(item_type: "round_result").order(:sequence)
    assert_equal true, results.last.payload["input_truncation_suspected"]
    refute results.first.payload.key?("input_truncation_suspected"), "round one had no source to be below"
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "k1")
    assert_empty agent_run.conversation_event_items.where(item_type: "context_compacted")

    honest = loop_at_the_wall(bulk: "the work so far", usage: { "input_tokens" => 5_000, "output_tokens" => 3 })
    schedule!(honest)
    settle!(honest, "round2", "and more", usage: { "input_tokens" => 5_040, "output_tokens" => 3 })
    payload = honest.conversation_event_items.where(item_type: "round_result").order(:sequence).last.payload
    refute payload.key?("input_truncation_suspected"), "growth is what a tail does"
  end

  # WHY IT FIRED is a closed vocabulary, one value for both hosts: the
  # exit's "fires once" assertion names `usage`, a person names `manual`,
  # and the two pre-send walls are one `wall` — the refusal is already on
  # the round, and "the request will not go" is the whole reason.
  test "a trigger names why it fired, from the closed vocabulary" do
    agent_run = loop_at_the_wall(bulk: "the work so far")
    round2 = node(agent_run, "round2")

    trigger = Conversations::Compaction::Trigger.overflow(round2)

    assert_equal "overflow", trigger.kind
    assert_equal agent_run.creating_user, trigger.authoring_user, "the loop's author signs the repair"
    assert_nil trigger.origin
    assert_nil trigger.input_public_id, "a standalone loop has no input to name"
    assert_nil trigger.overshoot, "the provider's refusal carries no number: it summarizes"
    assert_equal "wall", Conversations::Compaction::Trigger.wall(round2).kind
    assert_equal "usage", Conversations::Compaction::Trigger.usage(round2).kind
    assert_equal "manual", Conversations::Compaction::Trigger.manual(user: @human).kind
    assert_nil Conversations::Compaction::Trigger.manual(user: @human).overshoot, "a person asked to shrink"
    # The delegate-expiry fallback fires from the expired row: the loop's author signs it, and it
    # carries no number.
    fallback = Conversations::Compaction::Trigger.fallback(round2)
    assert_equal "fallback", fallback.kind
    assert_equal agent_run.creating_user, fallback.authoring_user
    assert_nil fallback.overshoot
    assert_equal %w[wall manual overflow usage fallback], Conversations::Compaction::Trigger::KINDS
    assert_raises(ArgumentError, "a kind outside the vocabulary is an authoring error, not a payload") do
      Conversations::Compaction::Trigger.new(kind: "panic", authoring_user: nil, origin: nil,
        input_public_id: nil)
    end

    # Bytes are the cheap candidate check; token walls retain their own unit
    # so the prune arm also checks the actual counter's reduction.
    walled = Conversations::Compaction::Trigger.wall(round2,
      overshoot: Conversations::Compaction::Overshoot.tokens(300))
    assert_equal 1_200, walled.overshoot.bytes
    assert_equal 300, walled.overshoot.tokens
    assert_equal 700, Conversations::Compaction::Overshoot.bytes(700).bytes
    assert_nil Conversations::Compaction::Overshoot.bytes(700).tokens
    assert_raises(ArgumentError) { Conversations::Compaction::Overshoot.bytes(0) }
  end

  # WHICH LANES CAN COUNT EXACTLY — pinned, because compaction's reach is
  # a function of it. Only a tokenizer we can run offline is exact; an
  # ANCHORED counter multiplies a stand-in tokenizer by a safety factor
  # and says so. An exact-only arming rule therefore left the repair dead
  # on most of what ships, which is why an estimate arms it too.
  test "most shipped lanes cannot count exactly, which is why estimates arm the repair" do
    counters = DevModelLane.each_catalog_profile
      .select { |profile| profile.workload == "text_generation" }
      .to_h { |profile| [profile.profile_id, profile.token_counter&.kind] }

    anchored = counters.select { |_id, kind| kind == "anchored" }
    assert anchored.any? { |id, _| id.start_with?("anthropic/") },
      "anthropic counts by anchored estimate, never exactly"

    anchored.each_key do |id|
      profile = DevModelLane.each_catalog_profile.find { |p| p.profile_id == id }
      counted = ModelRequests::TokenCount.count(profile: profile, segments: ["hello world"])
      assert_predicate counted, :counted?
      refute_predicate counted, :exact?, "#{id} must not claim exactness it does not have"
    end
  end

  # A lane with NO counter is measured bytes-as-tokens, which overstates
  # three or four times. Arming on that would compact a quarter-full
  # context, so such a lane keeps the byte wall it always had.
  test "a lane that declares no counter is not armed by a byte bound" do
    uncounted = DevModelLane.each_catalog_profile
      .find { |p| p.workload == "text_generation" && p.token_counter.nil? }
    skip "every text lane declares a counter" if uncounted.nil?

    counted = ModelRequests::TokenCount.count(profile: uncounted, segments: ["hello"])
    refute_predicate counted, :exact?
    assert_operator counted.tokens, :>=, 5, "bytes, not tokens - a bound, not an estimate"
  end
end
