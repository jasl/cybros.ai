require "test_helper"
require "test_helpers/log_capture"
require "test_helpers/refused_step_test_helper"

# A STEP A PROVIDER'S CLASSIFIER REFUSED RE-RUNS ONCE ON THE MODEL ITS
# ANSWERER DECLARED. The kernel reads the answerer's `fallback_model` live
# at the switch, resolves it against the step's own request, and requeues
# the step under a fresh generation on it — the refused invocation sealed
# as evidence, the switch narrated and written on the row. It chooses no
# model: no declaration, no switch. The step's own history bounds it: once
# per step, never back to a model that refused it, and neither a person's
# retry nor a new declaration re-arms it.
class AgentLoops::RefusalFallbackTest < ActiveJob::TestCase
  include RefusedStepTestHelper
  include AgentMembershipTestHelper
  include LogCapture

  SWITCH = { "from" => "dev/mock-text", "reason" => "model_refused", "category" => "cyber" }.freeze

  setup do
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @attempts = {}
    declare_tools!(@agent, default_model: "dev/mock-text", fallback_model: "dev/mock-unmetered")
  end

  test "a refused compose member re-runs once on the answerer's declared fallback and its reader gets the answer" do
    agent_loop = composed_loop(creating_user: @agent)

    lines = capture_log { refuse!(agent_loop, "r1t0-review") }

    assert_equal ["event=model_fallback loop=#{agent_loop.public_id} task=r1t0-review from=dev/mock-text " \
                  "to=dev/mock-unmetered reason=model_refused category=cyber\n"],
      lines.grep(/event=model_fallback/), "the switch is named once, after it committed"
    review = node(agent_loop, "r1t0-review")
    assert_equal ["running", 1, "mock-unmetered", 0],
      review.values_at(:status, :execution_generation, :model_ref, :auto_retries_used)
    assert_equal({ "model_change" => SWITCH }, review.output_summary, "a new execution starts its own summary")
    assert_not_predicate agent_loop.reload, :mail_model_fallback_used?
    refused, fallback = step_invocations(review).to_a
    assert_equal %w[completed refused mock-text], refused.values_at(:status, :finish_quality, :model_ref)
    assert_equal "mock-unmetered", fallback.model_ref

    assert_equal [SWITCH.merge("to" => "dev/mock-unmetered")],
      feed(agent_loop, "task_status").filter_map { |item| item["model_change"] }
    round = feed(agent_loop, "round_result").find { |item| item["task_key"] == "r1t0-review" }
    assert_equal %w[waiting dev/mock-text refused cyber],
      round.values_at("status", "model", "finish_quality", "refusal_category")

    # A branch never moves the main line: the spine and the sibling keep
    # their trio.
    assert_equal "mock-text", node(agent_loop, "r1t0-summary").model_ref
    assert_equal "mock-text", AgentLoops::CurrentModel.for(agent_loop).model_ref

    run_step!(agent_loop, "r1t0-review", sse_success("the review"))

    review.reload
    assert_equal "completed", review.status
    assert_equal({ "model_change" => SWITCH }, review.output_summary, "a served step reads no refused quality")
    wire = round_request_entries(node(agent_loop, "r1t0-summary")).to_json
    assert_includes wire, "Mock: the review", "the reader reads the fallback's answer"
    assert_not_includes wire, ModelInvocation::DECLINED_KEY
    assert_not_includes wire, AgentLoops::TaskResultEnvelope::EMPTY
  end

  test "a fallback that declines too stands, with both facts on the row and no third run" do
    agent_loop = composed_loop(creating_user: @agent)
    refuse!(agent_loop, "r1t0-review")

    refuse!(agent_loop, "r1t0-review", category: "bio")

    review = node(agent_loop, "r1t0-review")
    assert_equal %w[failed model_refused], review.values_at(:status, :error_key)
    assert_equal "dev/mock-unmetered declined this step (bio), so it failed with no output; it was already re-run " \
                 "once after dev/mock-text declined it (cyber), so nothing re-ran it again",
      review.error_detail
    assert_equal({ "model_change" => SWITCH, "finish_quality" => "refused", "refusal_category" => "bio" },
      review.output_summary)
    assert_equal 2, step_invocations(review).count
    assert_equal "running", agent_loop.reload.status, "the absorbed member resolves; its reader runs"
  end

  # Within the turn the switch sticks by inheritance: the continuation a
  # switched round mints is born on the round's trio, and the loop's
  # current model — the place a follower reads the model in use — says so.
  test "a refused spine round re-runs on the fallback and its continuation inherits it" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, agent_loop = materialize_loop_reply!(conversation, agent: @agent)
    schedule(agent_loop)

    refuse!(agent_loop, "r1")
    assert_equal %w[running mock-unmetered], node(agent_loop, "r1").values_at(:status, :model_ref)
    run_step!(agent_loop, "r1", sse_success("reading", tool_calls: [
      { id: "call_1", name: "read_file", arguments: { path: "a" }.to_json },
    ]))

    assert_equal "mock-unmetered", node(agent_loop, "r2").model_ref
    assert_equal "mock-unmetered", AgentLoops::CurrentModel.for(agent_loop.reload).model_ref
    assert_equal "dev/mock-unmetered", AgentAPI::AgentLoopPresenter.full(agent_loop).dig(:turn, :model, :model)
  end

  # The answerer's declaration, never the creator's and never the host's
  # default answerer's: a group turn addressed to a peer runs as the peer.
  test "the turn's answerer's fallback is read, not the conversation's default answerer's" do
    peer = create_agent_member(display_name: "Peer")
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    conversation.conversation_access_entries.create!(user: peer, level: "full")
    declare_tools!(peer, fallback_model: "dev/mock-windowless")
    post_input!(conversation, acting_user: @human, kind: "direct_reply", text: "go", provider_id: "dev",
      model_ref: "mock-text", answering_user_public_id: "@#{peer.handle}")
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    agent_loop = conversation.conversation_turns.order(:position).last.active_variant.agent_loop
    assert_equal peer, agent_loop.answering_user
    schedule(agent_loop)

    refuse!(agent_loop, "r1")

    assert_equal %w[running mock-windowless], node(agent_loop, "r1").values_at(:status, :model_ref)
  end

  # The bound is the step's own history, so nothing renews it: a refusal
  # that stood for want of a declaration stays the step's one refusal, and
  # neither a declaration made since nor a person's retry turns the next
  # refusal into a switch.
  test "neither a person's retry nor a later declaration re-arms the switch" do
    declare_tools!(@agent)
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, agent_loop = materialize_loop_reply!(conversation, agent: @agent)
    schedule(agent_loop)
    refuse!(agent_loop, "r1")
    assert_equal "failed", node(agent_loop, "r1").status

    declare_tools!(@agent, fallback_model: "dev/mock-unmetered")
    retried = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "r1", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    assert_equal({}, node(agent_loop, "r1").output_summary, "a queued re-run reads no stale refusal")
    schedule(agent_loop)
    refuse!(agent_loop, "r1")

    round = node(agent_loop, "r1")
    assert_equal %w[failed mock-text], round.values_at(:status, :model_ref)
    assert_equal "dev/mock-text declined this step (cyber), so it failed with no output; it was already re-run " \
                 "once after dev/mock-text declined it (cyber), so nothing re-ran it again",
      round.error_detail
    assert_equal 2, step_invocations(round).count
  end

  # A named model is switched too: the node keeps no provenance of who
  # chose its model, and a profile that wants no switch declares none. A
  # step already ON the fallback has nowhere to go, and the stand says so.
  test "a step whose author named a model is switched, and one authored on the fallback stands" do
    named = seed(model("m", "model" => { "model" => "dev/mock-windowless" }), creating_user: @agent)
    start_loop(named)
    refuse!(named, "m")
    assert_equal %w[running mock-unmetered], node(named, "m").values_at(:status, :model_ref)

    on_fallback = seed(model("m", "model" => { "model" => "dev/mock-unmetered" }), creating_user: @agent)
    start_loop(on_fallback)
    refuse!(on_fallback, "m")

    step = node(on_fallback, "m")
    assert_equal %w[failed model_refused], step.values_at(:status, :error_key)
    assert_equal "dev/mock-unmetered declined this step (cyber), so it failed with no output; the declared " \
                 "fallback model is the one that declined it, so nothing re-ran it",
      step.error_detail
    assert_equal 1, step_invocations(step).count
  end
end
