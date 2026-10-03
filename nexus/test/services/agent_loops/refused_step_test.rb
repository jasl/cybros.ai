require "test_helper"
require "test_helpers/refused_step_test_helper"

# A PROVIDER REFUSAL FAILS THE WORK IT WAS FOR. The invocation completed —
# the exchange happened and was billed — but the step it answered has no
# answer, so the step settles `failed / model_refused` and every reader of a
# failure reads it: the envelope a model gets, the task read, the turn. The
# bytes a reading model gets are the kernel's sentence — who declined, the
# category, that the step failed, and why nothing re-ran it — never the
# provider's message to integrators and never `(task completed with no
# output)`. A refusal never spends the step's retry budget: re-sending the
# same request to the same model usually earns another refusal.
class AgentLoops::RefusedStepTest < ActiveJob::TestCase
  include RefusedStepTestHelper

  setup do
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @attempts = {}
  end

  test "a refused compose member fails model_refused and its reader reads the kernel's sentence" do
    agent_loop = composed_loop
    review = node(agent_loop, "r1t0-review")
    assert_equal [1, "absorb"], [review.retry_budget, review.on_failure], "a retry was available to spend"

    refuse!(agent_loop, "r1t0-review")

    review.reload
    sentence = "dev/mock-text declined this step (cyber), so it failed with no output; no fallback model is " \
               "declared for it, so nothing re-ran it"
    assert_equal ["failed", "model_refused", sentence], review.values_at(:status, :error_key, :error_detail)
    assert_equal({ "finish_quality" => "refused", "refusal_category" => "cyber" }, review.output_summary)
    assert_equal [0, 0], [review.auto_retries_used, review.execution_generation], "a refusal is not a retry"
    assert_equal 1, step_invocations(review).count
    assert_equal "model_refused", AgentLoops::TaskResultProjection.call(review).dig("error", "key")

    summary = node(agent_loop, "r1t0-summary")
    assert_equal "running", summary.status, "an absorbed failure resolves; its reader runs"
    assert_equal "running", agent_loop.reload.status
    texts = round_request_entries(summary).filter_map { |entry| entry.dig("parts", 0, "text") }.join("\n")
    assert_includes texts, "<task_result task=\"r1t0-review\" status=\"failed\">\n<prompt>Review the patch</prompt>\n" \
                           "model_refused: #{sentence}\n#{AgentLoops::TaskResultEnvelope::DECLINED}\n</task_result>",
      "what happened, then what the reading model can do next"
    assert_not_includes texts, AgentLoops::TaskResultEnvelope::EMPTY
    assert_not_includes texts, EXPLANATION, "the provider's sentence is for people, not the reading model"

    round = agent_loop.conversation_event_items.where(item_type: "round_result").order(:sequence)
      .map(&:payload).find { |payload| payload["task_key"] == "r1t0-review" }.except("agent_loop_public_id")
    assert_equal({ "task_key" => "r1t0-review", "status" => "failed", "model" => "dev/mock-text",
                   "finish_quality" => "refused", "refusal_category" => "cyber", "error_detail" => EXPLANATION },
      round, "the round says what the provider answered; the task says what the work came to")
  end

  test "a refusal whose provider names no category drops the parenthesis" do
    agent_loop = composed_loop
    run_step!(agent_loop, "r1t0-review", sse_refused("I can't help with that."))

    review = node(agent_loop, "r1t0-review")
    assert_equal "dev/mock-text declined this step, so it failed with no output; no fallback model is declared " \
                 "for it, so nothing re-ran it",
      review.error_detail
    assert_equal({ "finish_quality" => "refused" }, review.output_summary, "no invented category word")
  end

  # The stand names the party that could have declared a fallback: the
  # agent answering the step, never a person who has no such setting.
  test "an agent that declares no fallback is named as the one that declares none" do
    declare_tools!(@agent)
    agent_loop = composed_loop(creating_user: @agent)
    refuse!(agent_loop, "r1t0-review")

    assert_equal "dev/mock-text declined this step (cyber), so it failed with no output; @#{@agent.handle} " \
                 "declares no fallback model, so nothing re-ran it",
      node(agent_loop, "r1t0-review").error_detail
  end

  # A word that does not say what it means rides with the gem's gloss.
  test "an opaque category rides with its meaning" do
    agent_loop = composed_loop
    refuse!(agent_loop, "r1t0-review", category: "reasoning_extraction")

    assert_equal "dev/mock-text declined this step (reasoning_extraction: the request asks for the model's own " \
                 "reasoning), so it failed with no output; no fallback model is declared for it, so nothing re-ran it",
      node(agent_loop, "r1t0-review").error_detail
  end

  # A content-protection stop is the provider's verdict on the CONTENT: the
  # work fails at once and nothing is re-sent, retry budget or not.
  test "a blocked step fails at once and says nothing is re-sent" do
    agent_loop = composed_loop
    blocked = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret",
      adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
        "candidates" => [{ "content" => { "parts" => [{ "text" => "partial" }] }, "finishReason" => "SPII" }],
        "usageMetadata" => { "promptTokenCount" => 3, "candidatesTokenCount" => 1, "totalTokenCount" => 4 },
      }))
    ).create(model: "gemini-3.7-flash", input: "Hello")

    run_provider_step!(agent_loop, "r1t0-review", blocked, adapter_profile: "gemini_generate_content")

    review = node(agent_loop, "r1t0-review")
    assert_equal ["failed", "model_refused",
                  "dev/mock-text blocked this step (SPII: sensitive personal data), so it failed with no output; " \
                  "blocked content is never sent to another model"],
      review.values_at(:status, :error_key, :error_detail)
    assert_equal({ "finish_quality" => "blocked", "refusal_category" => "SPII" }, review.output_summary)
    assert_equal 1, step_invocations(review).count
  end

  # A spine round's compile default is `halt`: the loop holds for a person,
  # the turn fails naming the refusal, and the person's retry may name
  # another model — which clears the row, so nothing reads a stale `refused`
  # while the re-run is queued.
  test "a refused spine round halts for a person whose retry names a model and clears the row" do
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent)
    turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent)
    schedule_loop!(agent_loop)

    refuse!(agent_loop, "r1")
    Conversations::Turns::Converge.call

    assert_equal %w[needs_attention halt_failure], agent_loop.reload.values_at(:status, :attention_reason)
    assert_equal "failed", turn.reload.status
    settled = @conversation.conversation_event_items.where(item_type: "turn_status").order(:sequence).last.payload
    assert_equal ["failed", "model_refused", ["r1"]], settled.values_at("status", "error_key", "blocked_task_keys")

    result = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "r1", acting_user: @human, model: { "model" => "dev/mock-unmetered" }
    ))
    assert_predicate result, :accepted?
    round = node(agent_loop, "r1")
    assert_equal ["queued", {}, "mock-unmetered"], round.values_at(:status, :output_summary, :model_ref)

    schedule_loop!(agent_loop)
    run_step!(agent_loop, "r1", sse_success("answered on the other model"))
    Conversations::Turns::Converge.call
    assert_equal "completed", agent_loop.reload.status
    assert_equal({}, node(agent_loop, "r1").output_summary)
  end

  # A declined round leaves no bodies, so a failed round the history replays
  # whatever its status renders as nothing: no partial words, no call paired
  # with an unanswered result in every later turn.
  test "a halted refused round replays as nothing in the next turn's history" do
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent)
    _turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent)
    schedule_loop!(agent_loop)
    refused = anthropic_result(
      "content" => [{ "type" => "text", "text" => "Here is how" },
                    { "type" => "tool_use", "id" => "toolu_1", "name" => "read_file", "input" => { "path" => "a" } }],
      "stop_reason" => "refusal", "stop_details" => { "category" => "cyber", "explanation" => EXPLANATION }
    )
    run_provider_step!(agent_loop, "r1", refused, adapter_profile: "anthropic_messages")
    Conversations::Turns::Converge.call
    assert_equal "needs_attention", agent_loop.reload.status

    _next_turn, next_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "try something else")
    schedule_loop!(next_loop)

    wire = round_request_entries(node(next_loop, "r1")).to_json
    assert_not_includes wire, "Here is how"
    assert_not_includes wire, "toolu_1"
    assert_not_includes wire, AgentLoops::RoundReplay::Pairing::UNANSWERED
  end

  test "a canceling loop's refused step settles canceled and is never re-run" do
    agent_loop = composed_loop
    stopped = AgentLoops::Stop.call(AgentLoops::Stop::Command.new(agent_loop: agent_loop, acting_user: @human, force: false))
    assert_equal "canceling", agent_loop.reload.status, stopped.inspect

    refuse!(agent_loop, "r1t0-review")

    review = node(agent_loop, "r1t0-review")
    assert_equal "canceled", review.status
    assert_equal 1, step_invocations(review).count
  end

  # A race's loser that runs out after the race settled has no reader left:
  # it fails where it stands, saying so, and never holds the loop.
  test "a refused step nothing waits for fails where it stands" do
    agent_loop = seed(
      parallel(model("fast"), model("slow"), until: "any", key: "race", losers: "run_out"),
      model("after")
    )
    start_loop(agent_loop)
    run_step!(agent_loop, "fast", sse_success("the answer"))
    assert_equal "completed", node(agent_loop, "race").status
    assert_equal "running", node(agent_loop, "slow").status

    refuse!(agent_loop, "slow")

    slow = node(agent_loop, "slow")
    assert_equal ["failed", "model_refused",
                  "dev/mock-text declined this step (cyber), so it failed with no output; nothing waits for it " \
                  "any more, so nothing re-ran it"],
      slow.values_at(:status, :error_key, :error_detail)
    run_step!(agent_loop, "after", sse_success("done"))
    assert_equal "completed", agent_loop.reload.status, "a settled race absorbs its loser"
  end

  # A branch tip's paired result is data the model reads, never an error
  # flag: the envelope's status and body carry the refusal.
  test "a waited task whose branch was refused pairs the kernel's sentence as data" do
    agent_loop = seed(model("round1", "tools" => [Nexus::Tools::TASK, LoopLaneTestHelper::READ_TOOL], "prompt" => "go"))
    start_loop(agent_loop)
    apply_via(step_attempt(agent_loop, "round1"), sse_success("delegating", tool_calls: [
      { id: "call_0", name: "task", arguments: { prompt: "Normalise the fetched output", wait: true }.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ScheduleJob]) { schedule(agent_loop) }

    refuse!(agent_loop, "r1t0-model-1")
    schedule(agent_loop)

    paired = round_request_entries(node(agent_loop, "r1")).find { |entry| entry["type"] == "tool_result_item" }
    assert_includes paired.dig("payload", "output"),
      "<task_result task=\"r1t0\" status=\"failed\">\n<prompt>Normalise the fetched output</prompt>\n" \
      "model_refused: dev/mock-text declined this step (cyber)"
    assert_includes paired.dig("payload", "output"), "#{AgentLoops::TaskResultEnvelope::DECLINED}\n</task_result>"
    assert_not paired.dig("payload", "is_error"), "a branch tip's envelope is data, never an error flag"
  end
end
