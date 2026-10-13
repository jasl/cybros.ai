require "test_helper"
require "test_helpers/log_capture"
require "test_helpers/refused_step_test_helper"

# A provider refusal advances through the execution's captured fallback order.
# Each prior invocation stays sealed, and the task's history prevents retries
# and later declaration edits from renewing a route that already failed.
class AgentRuns::RefusalFallbackTest < ActiveJob::TestCase
  include RefusedStepTestHelper
  include AgentMembershipTestHelper
  include LogCapture

  SWITCH = { "from" => "dev/mock-text", "reason" => "model_refused", "category" => "cyber" }.freeze

  setup do
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @attempts = {}
    declare_tools!(@agent, default_model: "dev/mock-text", fallback_models: ["dev/mock-unmetered"])
  end

  test "a refused model branch re-runs once on the answerer's declared fallback and its reader gets the answer" do
    agent_run = composed_loop(creating_user: @agent)

    lines = capture_log { refuse!(agent_run, "r1t0-review") }

    assert_equal ["event=model_fallback loop=#{agent_run.public_id} task=r1t0-review from=dev/mock-text " \
                  "to=dev/mock-unmetered reason=model_refused category=cyber\n"],
      lines.grep(/event=model_fallback/), "the switch is named once, after it committed"
    review = node(agent_run, "r1t0-review")
    assert_equal ["running", 1, "mock-unmetered"],
      review.values_at(:status, :execution_generation, :model_ref)
    assert_equal({ "model_change" => SWITCH }, review.output_summary, "a new execution starts its own summary")
    assert_equal ["dev/mock-unmetered"], agent_run.reload.fallback_models
    refused, fallback = step_invocations(review).to_a
    assert_equal %w[completed refused mock-text], refused.values_at(:status, :finish_quality, :model_ref)
    assert_equal "mock-unmetered", fallback.model_ref

    assert_equal [SWITCH.merge("to" => "dev/mock-unmetered")],
      feed(agent_run, "task_status").filter_map { |item| item["model_change"] }
    round = feed(agent_run, "round_result").find { |item| item["task_key"] == "r1t0-review" }
    assert_equal %w[waiting dev/mock-text refused cyber],
      round.values_at("status", "model", "finish_quality", "refusal_category")

    # A branch never moves the main line: the mainline and the sibling keep
    # their trio.
    assert_equal "mock-text", node(agent_run, "r1t0-summary").model_ref
    assert_equal "mock-text", AgentRuns::CurrentModel.for(agent_run).model_ref

    run_step!(agent_run, "r1t0-review", sse_success("the review"))

    review.reload
    assert_equal "completed", review.status
    assert_equal({ "model_change" => SWITCH }, review.output_summary, "a served step reads no refused quality")
    wire = round_request_entries(node(agent_run, "r1t0-summary")).to_json
    assert_includes wire, "Mock: the review", "the reader reads the fallback's answer"
    assert_not_includes wire, ModelInvocation::DECLINED_KEY
    assert_not_includes wire, AgentRuns::TaskResultEnvelope::EMPTY
  end

  test "a fallback that declines too stands, with both facts on the row and no third run" do
    agent_run = composed_loop(creating_user: @agent)
    refuse!(agent_run, "r1t0-review")

    refuse!(agent_run, "r1t0-review", category: "bio")

    review = node(agent_run, "r1t0-review")
    assert_equal %w[failed model_refused], review.values_at(:status, :error_key)
    assert_equal "dev/mock-unmetered declined this step (bio), so it failed with no output; " \
                 "no remaining configured fallback can take this request (no_selectable_fallback), so nothing re-ran it",
      review.error_detail
    assert_equal({ "model_change" => SWITCH, "finish_quality" => "refused", "refusal_category" => "bio" },
      review.output_summary)
    assert_equal 2, step_invocations(review).count
    assert_equal "running", agent_run.reload.status, "the absorbed member resolves; its reader runs"
  end

  # Within the turn the switch sticks by inheritance: the continuation a
  # switched round mints is born on the round's trio, and the loop's
  # current model — the place a follower reads the model in use — says so.
  test "a refused mainline round re-runs on the fallback and its continuation inherits it" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, agent_run = materialize_loop_reply!(conversation, agent: @agent)
    schedule(agent_run)

    refuse!(agent_run, "r1")
    assert_equal %w[running mock-unmetered], node(agent_run, "r1").values_at(:status, :model_ref)
    run_step!(agent_run, "r1", sse_success("reading", tool_calls: [
      { id: "call_1", name: "read_file", arguments: { path: "a" }.to_json },
    ]))

    assert_equal "mock-unmetered", node(agent_run, "r2").model_ref
    assert_equal "mock-unmetered", AgentRuns::CurrentModel.for(agent_run.reload).model_ref
    assert_equal "dev/mock-unmetered", AgentAPI::AgentRunPresenter.full(agent_run).dig(:turn, :model, :model)
  end

  # The answerer's declaration, never the creator's and never the host's
  # default answerer's: a group turn addressed to a peer runs as the peer.
  test "the turn's answerer's fallback is read, not the conversation's default answerer's" do
    peer = create_agent_member(display_name: "Peer")
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    conversation.conversation_access_entries.create!(user: peer, level: "full")
    declare_tools!(peer, fallback_models: ["dev/mock-windowless"])
    post_input!(conversation, acting_user: @human, kind: "direct_reply", text: "go", provider_id: "dev",
      model_ref: "mock-text", answering_user_public_id: "@#{peer.handle}")
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    agent_run = conversation.conversation_turns.order(:position).last.active_variant.agent_run
    assert_equal peer, agent_run.answering_user
    schedule(agent_run)

    refuse!(agent_run, "r1")

    assert_equal %w[running mock-windowless], node(agent_run, "r1").values_at(:status, :model_ref)
  end

  # The bound is the step's own history, so nothing renews it: a refusal
  # that stood for want of a declaration stays the step's one refusal, and
  # neither a declaration made since nor a person's retry turns the next
  # refusal into a switch.
  test "neither a person's retry nor a later declaration re-arms the switch" do
    declare_tools!(@agent)
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    _turn, agent_run = materialize_loop_reply!(conversation, agent: @agent)
    schedule(agent_run)
    refuse!(agent_run, "r1")
    assert_equal "failed", node(agent_run, "r1").status

    declare_tools!(@agent, fallback_models: ["dev/mock-unmetered"])
    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "r1", acting_user: @human
    ))
    assert_predicate retried, :accepted?
    assert_equal({}, node(agent_run, "r1").output_summary, "a queued re-run reads no stale refusal")
    schedule(agent_run)

    round = node(agent_run, "r1")
    assert_equal %w[failed mock-text model_route_spent], round.values_at(:status, :model_ref, :error_key)
    assert_equal 1, step_invocations(round).count, "manual retry cannot renew the spent provider route"
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
    assert_equal "dev/mock-unmetered declined this step (cyber), so it failed with no output; " \
                 "no remaining configured fallback can take this request (no_selectable_fallback), so nothing re-ran it",
      step.error_detail
    assert_equal 1, step_invocations(step).count
  end
  test "three captured candidates advance in order despite a later declaration change" do
    declare_tools!(@agent, fallback_models: %w[dev/mock-unmetered dev/mock-windowless dev/mock-text])
    agent_run = seed(model("m", "prompt" => "go"), creating_user: @agent)
    start_loop(agent_run)
    declare_tools!(@agent, fallback_models: ["dev/mock-text-only"])

    refuse!(agent_run, "m")
    assert_equal "mock-unmetered", node(agent_run, "m").model_ref
    refuse!(agent_run, "m")
    assert_equal "mock-windowless", node(agent_run, "m").model_ref
    refuse!(agent_run, "m")

    step = node(agent_run, "m")
    assert_equal "failed", step.status
    assert_equal %w[mock-text mock-unmetered mock-windowless], step_invocations(step).pluck(:model_ref)
    assert_equal [1, 1, 1], step_invocations(step).map { |invocation| invocation.attempts.count }
  end

  test "a queued model hidden before admission skips without allocating an attempt" do
    agent_run = seed(model("m", "prompt" => "go"), creating_user: @agent)
    start_loop(agent_run)
    original = node(agent_run, "m").selected_model_invocation
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    policy.set_model_visibility("dev/mock-text", visible: false)
    policy.save!

    assert_empty ModelInvocations::AdmitQueuedWork.call.admitted
    assert_empty original.attempts
    assert_equal %w[canceled model_hidden], original.reload.values_at(:status, :failure_reason_key)
    converge(agent_run)

    assert_equal %w[running mock-unmetered], node(agent_run, "m").values_at(:status, :model_ref)
    assert_equal [0, 0], step_invocations(node(agent_run, "m")).map { |invocation| invocation.attempts.count }
    assert_equal 0, agent_run.model_invocations.where(status: "failed").count
    assert_equal "mock-unmetered", step_attempt(agent_run, "m").model_invocation.model_ref
  end

  test "pre-IO hidden model is skipped without a failed attempt or retry" do
    agent_run = seed(model("m", "prompt" => "go"), creating_user: @agent)
    start_loop(agent_run)
    attempt = step_attempt(agent_run, "m")
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    policy.set_model_visibility("dev/mock-text", visible: false)
    policy.save!

    fake_dispatch(sse_success("must not run")) do |adapter|
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue")
      assert_empty adapter.requests
    end
    converge(agent_run)

    assert_equal %w[canceled not_applicable], attempt.reload.values_at(:status, :settlement_state)
    assert_nil attempt.provider_started_at
    assert_nil receipt_for(attempt)
    assert_equal %w[running mock-unmetered], node(agent_run, "m").values_at(:status, :model_ref)
    assert_equal [1, 0], step_invocations(node(agent_run, "m")).map { |invocation| invocation.attempts.count }
    assert_equal 0, agent_run.model_invocations.where(status: "failed").count
  end

  test "explicit repair can use an unspent route without renewing the refused route" do
    declare_tools!(@agent, fallback_models: [])
    agent_run = seed(model("m", "prompt" => "go"), creating_user: @agent)
    start_loop(agent_run)
    refuse!(agent_run, "m")

    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "m", acting_user: @human, model: { "model" => "dev/mock-windowless" }))
    assert_predicate retried, :accepted?
    schedule(agent_run)
    assert_equal "mock-windowless", node(agent_run, "m").model_ref
    assert_equal %w[mock-text mock-windowless], step_invocations(node(agent_run, "m")).pluck(:model_ref)
  end
end
