require "test_helper"

# The request-cache boundary: the loop's continuation chain is DESIGNED around cache reuse, so the
# assertions here are about the request that actually goes out — the stable head, the rolling tail,
# and the prefix that must not move between rounds. (The ECONOMICS — that a real provider reads what
# we wrote — is real-LLM lane; a mock cannot see a cache.)
class AgentRuns::PromptCacheTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  MARKER = Nexus::PromptCache::Breakpoints.marker("5m")
  TOOLS = [
    { "type" => "function", "function" => { "name" => "write_file" } },
    { "type" => "function", "function" => { "name" => "read_file" } },
  ].freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def schedule!(agent_run)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def step_attempt(agent_run, key)
    @admitted ||= {}
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @admitted[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    clear_enqueued_jobs
    @admitted.fetch(node(agent_run, key).selected_model_invocation_id)
  end

  def run_step!(agent_run, behaviour, key:)
    apply_via(step_attempt(agent_run, key), behaviour)
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  # The request as it goes to the wire, built exactly as dispatch builds it.
  def payload(agent_run, key)
    JSON.parse(build(step_attempt(agent_run, key)).request.payload)
  end

  test "a wire without explicit breakpoints is byte-untouched, and its prefix still pays" do
    agent_run = seed(
      model("ask", "prompt" => "read it", "tools" => TOOLS,
        "instructions" => "You are terse."),
    )
    start!(agent_run)

    body = payload(agent_run, "ask")
    assert_equal "You are terse.", body.fetch("instructions"),
      "the system channel rides the wire's own field - segment one"
    assert_not body.to_json.include?("cache_control"),
      "this lane speaks responses, where caching is IMPLICIT on prefix " \
        "stability - the kernel emits nothing and the stability laws do the work"
    assert_equal [{ "role" => "user",
                    "content" => [{ "type" => "input_text", "text" => "read it" }] }],
      body.fetch("input"),
      "and round one is MESSAGE-SHAPED from birth - the predecessor paid a " \
        "full-price joined-string first turn before caching could engage"
  end

  test "the tool list is canonically ordered, so a re-authored set cannot bust the prefix" do
    scrambled = seed(model("a", "tools" => TOOLS))
    reversed = seed(model("a", "tools" => TOOLS.reverse))

    assert_equal node(scrambled, "a").tool_definitions,
      node(reversed, "a").tool_definitions,
      "a tool list is a SET, and it renders at the very front of the cached " \
        "prefix - authoring order must not decide the bytes"
    assert_equal %w[read_file write_file],
      node(scrambled, "a").tool_definitions.map { |t| t.dig("function", "name") }
  end

  test "the prefix does not move between rounds: only the tail marker travels" do
    agent_run = seed(
      model("ask", "prompt" => "go", "tools" => TOOLS, "instructions" => "sys"),
    )
    start!(agent_run)
    first = payload(agent_run, "ask")

    run_step!(agent_run, sse_success("calling", tool_calls: [
      { id: "c1", name: "read_file", arguments: "{}" },
    ]), key: "ask")
    AgentRuns::Parks::Settle.call(node: node(agent_run, "r1t0"), trusted: true,
      content: "contents", outcome: "completed")
    schedule!(agent_run)
    second = payload(agent_run, "r1")

    assert_equal first.fetch("instructions"), second.fetch("instructions"),
      "the stable head is byte-identical round over round - one changed byte " \
        "there invalidates everything below it"
    assert_equal first.fetch("tools"), second.fetch("tools"),
      "and so is the tool list, which renders at the very front"

    assert_equal first.fetch("input"),
      second.fetch("input").first(first.fetch("input").length),
      "the wire prefix EXTENDS rather than shifting - the only shape a " \
        "provider prefix cache can match"
  end

  test "the round's own usage narrates cache reuse" do
    agent_run = seed(model("ask", "prompt" => "go"))
    start!(agent_run)
    run_step!(agent_run, sse_success("done", usage: {
      "input_tokens" => 100, "output_tokens" => 5,
      "cache_read_input_tokens" => 90, "cache_creation_input_tokens" => 10,
    }), key: "ask")

    usage = agent_run.conversation_event_items.where(item_type: "usage").last
    assert_equal 90, usage.payload.fetch("cache_read_tokens")
    assert_equal 10, usage.payload.fetch("cache_creation_tokens"),
      "a tool loop re-sends its whole prefix every round, so reuse is the " \
        "dominant cost term - a transcript that cannot show it cannot be tuned"
  end

  # THE TIER AND THE TAIL BY THE REQUEST'S KIND, stamped where the request is minted: the mainline of a
  # conversation's turn is paced by a person and takes the 1-hour tier; a branch — an authored model,
  # a detached step, a `task` delegate — and every round of a subagent's conversation are read back
  # within seconds and take 5 minutes, as a standalone loop's rounds and a InferenceRequest do; the
  # summarizer's request writes no marker at all (nobody reads its serialized history back).
  test "every round's mint stamps its request kind: standalone and branch 5 minutes" do
    standalone = seed(model("ask", "prompt" => "go"), detached(model("side", "prompt" => "aside")))
    start!(standalone)

    assert_equal({ "kind" => "standalone", "tier" => "5m", "tail" => true },
      fact_of(node(standalone, "ask")))
    run_step!(standalone, sse_success("went"), key: "ask")
    assert_equal({ "kind" => "branch", "tier" => "5m", "tail" => true },
      fact_of(node(standalone, "side")), "a detached step is a branch")
  end

  test "a conversation's mainline round takes 1 hour, a subagent's 5 minutes, the summarizer none" do
    agent = users(:agent)
    declare_tools!(agent)
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent)
    _turn, agent_run = materialize_loop_reply!(conversation, agent: agent)
    schedule!(agent_run)
    assert_equal({ "kind" => "mainline", "tier" => "1h", "tail" => true }, fact_of(node(agent_run, "r1")))

    child = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent,
      parent_conversation_public_id: conversation.public_id)
    _child_turn, child_loop = materialize_loop_reply!(child, agent: agent)
    schedule!(child_loop)
    assert_equal({ "kind" => "child", "tier" => "5m", "tail" => true }, fact_of(node(child_loop, "r1")))

    idle = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent)
    post_input!(idle, acting_user: @human, text: "something to summarize")
    Conversations::Inputs::ApplyNext.drain(conversation_id: idle.id)
    compacted = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: idle.reload, acting_user: @human, model: "dev/mock-text"
    ))
    assert_predicate compacted, :accepted?, compacted.outcome.inspect
    summary_loop = compacted.value.turn.active_variant.agent_run
    schedule!(summary_loop)
    assert_equal({ "kind" => "summary" }, fact_of(node(summary_loop, "k1")), "no marker at all")
  end

  # A BRANCH INSIDE A CONVERSATION'S TURN is still a branch: its own later rounds read it back within
  # seconds, so a delegated model, its next round and another `task` delegate take 5 minutes while the
  # mainline that started them takes the hour.
  test "a conversation's delegated model, its later round and another task delegate take 5 minutes" do
    agent = users(:agent)
    declare_tools!(agent, tools: [READ_TOOL, Nexus::ToolRegistry.function_definition("wait"), Nexus::Tools::DELEGATE_TASK])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent)
    _turn, agent_run = materialize_loop_reply!(conversation, agent: agent)
    schedule!(agent_run)
    assert_equal MAINLINE, fact_of(node(agent_run, "r1"))
    apply_via(step_attempt(agent_run, "r1"), sse_success("fanning", tool_calls: [
      { id: "review_call", name: "delegate_task",
        arguments: { prompt: "Review the patch" }.to_json },
      { id: "task_call", name: "delegate_task", arguments: { prompt: "look into it" }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::ScheduleJob]) do
      schedule!(agent_run)
    end

    review = agent_run.agent_run_tasks.find_by!(tool_call_id: "review_call")
    member = node(agent_run, "#{review.node_key}-model-1")
    task = agent_run.agent_run_tasks.find_by!(tool_call_id: "task_call")
    delegate = agent_run.agent_run_tasks.where(expansion_parent_id: task.id).sole
    assert_equal BRANCH, fact_of(member), "a delegated model"
    assert_equal BRANCH, fact_of(delegate), "a task delegate"

    run_step!(agent_run, sse_success("reading", tool_calls: [
      { id: "member_read", name: "read_file", arguments: { path: "a" }.to_json },
    ]), key: member.node_key)
    settled = AgentRuns::Parks::Settle.call(node: agent_run.agent_run_tasks.find_by!(tool_call_id: "member_read"),
      trusted: true, content: "contents of a", outcome: "completed")
    assert_predicate settled, :applied?
    schedule!(agent_run)
    later = agent_run.agent_run_tasks.where(type: AgentRunTasks::ModelTask.sti_name).order(:id).last
    assert_equal [member.node_key], later.input_from_node_keys.first(1), "the member's own next round"
    assert_equal BRANCH, fact_of(later), "a member's later round is its branch too"
  end

  # THE SUMMARIZER IS JUDGED FIRST: a mid-turn repair's summarizer runs as a branch of the round it
  # repairs, yet nobody reads its serialized history back — it writes no marker at all.
  test "a mid-turn repair's summarizer writes no marker, though it runs as a branch" do
    agent = users(:agent)
    declare_tools!(agent, tools: [READ_TOOL])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent)
    _turn, agent_run = materialize_loop_reply!(conversation, agent: agent)
    schedule!(agent_run)
    apply_via(step_attempt(agent_run, "r1"), sse_success("reading", tool_calls: [
      { id: "call_a", name: "read_file", arguments: { path: "a" }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    schedule!(agent_run)
    settled = AgentRuns::Parks::Settle.call(node: agent_run.agent_run_tasks.find_by!(tool_call_id: "call_a"),
      trusted: true, content: "contents of a", outcome: "completed")
    assert_predicate settled, :applied?

    compacted = AgentRuns::Tasks::Compact.call(AgentRuns::Tasks::Compact::Command.new(
      agent_run: agent_run, task_key: "r2", acting_user: @human
    ))
    assert_predicate compacted, :accepted?, compacted.outcome.inspect
    schedule!(agent_run)

    summarizer = node(agent_run, compacted.summary_task_key)
    assert_equal AgentRuns::Tasks::Compile::BRANCH, summarizer.continuation_source
    assert_equal({ "kind" => "summary" }, fact_of(summarizer), "no marker at all")
  end

  # The mints outside the loop lane: a tool-less reply and its regeneration take the conversation's
  # kind — a subagent's conversation its child's — and a InferenceRequest takes its own.
  test "a direct reply and its regeneration take the conversation's kind, a InferenceRequest its own" do
    agent = users(:agent)
    declare_tools!(agent, tools: [])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent)
    turn = direct_reply!(conversation)
    assert_equal MAINLINE, turn.active_variant.model_invocation.request_options.fetch("prompt_cache")
    apply_via(step_attempt_for(turn.active_variant.model_invocation), sse_success("answered"))
    Conversations::Turns::Converge.call
    clear_enqueued_jobs
    regenerated = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: conversation.reload, turn_public_id: turn.public_id, acting_user: @human,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    ))
    assert_predicate regenerated, :accepted?, regenerated.outcome.inspect
    assert_equal MAINLINE, regenerated.value.model_invocation.request_options.fetch("prompt_cache"), "a regeneration"

    child = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent,
      parent_conversation_public_id: conversation.public_id)
    assert_equal({ "kind" => "child", "tier" => "5m", "tail" => true },
      direct_reply!(child).active_variant.model_invocation.request_options.fetch("prompt_cache"))

    created = InferenceRequests::Create.call(port: DevModelLane.port, command: InferenceRequests::Create::Command.new(
      workspace: @workspace, creating_user: @human, workload: "text_generation",
      submitted: DevModelLane.submission_for("text_generation"), configuration: {},
      input: "say hi", upload_public_ids: [], billing_subject: nil, idempotency_key: SecureRandom.uuid
    ))
    assert_predicate created, :created?
    inference_request = InferenceRequest.find_by!(public_id: created.accepted.fetch("inference_request_public_id"))
    assert_equal({ "kind" => "inference_request", "tier" => "5m", "tail" => true },
      inference_request.model_invocation.request_options.fetch("prompt_cache"))
  end

  # Build reads the fact; a request minted with none (a bare row) takes 5 minutes with its tail and
  # says so on the placement line.
  test "an unstated request takes 5 minutes with its tail" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    bare = ModelInvocation.create!(
      conversation: conversation, creating_user: @human, internal_creation_key: "conversation_reply:x",
      provider_id: "dev", model_ref: "mock-text", request_options: {}, admission_deadline_seconds: 60
    )

    assert_equal ["unstated", "5m", true], Nexus::PromptCache::RequestKind.of(bare.request_options).deconstruct
  end

  def fact_of(node) = node.selected_model_invocation.request_options.fetch("prompt_cache")

  MAINLINE = { "kind" => "mainline", "tier" => "1h", "tail" => true }.freeze
  BRANCH = { "kind" => "branch", "tier" => "5m", "tail" => true }.freeze

  def direct_reply!(conversation)
    post_input!(conversation, acting_user: @human, kind: "direct_reply", text: "the prompt",
      provider_id: "dev", model_ref: "mock-text")
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    turn = conversation.conversation_turns.order(:position).last
    assert_equal ["direct_reply", nil], [turn.kind, turn.active_variant.agent_run]
    turn
  end

  def step_attempt_for(invocation)
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    invocation.attempts.order(:id).last
  end
end
