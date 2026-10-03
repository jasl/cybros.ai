require "test_helper"

# `task` — one bounded job to a new agent with an EMPTY context. The call is an ordinary fan member;
# its executor places ONE model step through the door compose uses, marked `branch`, `absorb`,
# carrying the round's surface minus the graph verbs. The WHEN word is `wait` on the call: by
# default the branch is detached, the continuation runs on and the wake delivers the answer later as
# a `<task_result>` message; with `wait: true` the round's continuation waits on the branch and its
# last word is the CALL's paired result.
class AgentLoops::TaskToolTest < ActiveJob::TestCase
  include InvocationHarness

  READ_FILE = { "type" => "function",
                "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } }.freeze
  PROMPT = "Review app/models/user.rb for N+1 queries. Answer file:line and a fix, or 'none'.".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def model(key, **over)
    super(key, "tools" => [Nexus::Tools::TASK, Nexus::Compose::DEFINITION, READ_FILE], **over)
  end

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    clear_enqueued_jobs
    schedule!(agent_loop)
  end

  def schedule!(agent_loop) = AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def step_attempt(agent_loop, key)
    invocation_id = node(agent_loop, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def loop_with_round
    agent_loop = seed(model("round1", "prompt" => "do the work", "instructions" => "you are a kernel"))
    start!(agent_loop)
    agent_loop
  end

  # A round that answers with `task` calls, driven through the scheduler,
  # the dispatch and the job. Each argument hash is one call, in order;
  # `wait:` is the CALL's word, given to every call of the round when set
  # (absent, the default: the branch is detached).
  def task_round!(agent_loop, *calls, key: "round1", wait: nil)
    tool_calls = calls.each_with_index.map do |arguments, index|
      arguments = arguments.merge(wait: wait) unless wait.nil?
      { id: "call_#{index}", name: "task", arguments: arguments.to_json }
    end
    apply_via(step_attempt(agent_loop, key), sse_success("delegating", tool_calls: tool_calls))
    AgentLoops::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ScheduleJob]) do
      schedule!(agent_loop)
    end
    agent_loop.reload
  end

  def run!(agent_loop, key, text)
    apply_via(step_attempt(agent_loop, key), sse_success(text))
    AgentLoops::ConvergeTerminalSteps.call
    schedule!(agent_loop)
  end

  # The branch answers with one tool call, so the driver expands it.
  def branch_calls!(agent_loop, key, text)
    apply_via(step_attempt(agent_loop, key), sse_success(text, tool_calls: [
      { id: "call_#{key}", name: "read_file", arguments: '{"path":"a"}' },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    schedule!(agent_loop)
  end

  def settle_tool!(agent_loop, key, text)
    AgentLoops::Parks::Settle.call(node: node(agent_loop, key), trusted: true,
      content: text, outcome: "completed")
    schedule!(agent_loop)
  end

  def sources_of(agent_loop, key)
    node(agent_loop, key).incoming_edges.includes(:from_node).map { |edge| edge.from_node.node_key }.sort
  end

  def tool_result(agent_loop, key) = node(agent_loop, key).content_bodies.find_by(role: "output")&.effective_text

  def tool_names(agent_loop, key)
    Array(node(agent_loop, key).tool_definitions).map { |definition| definition.dig("function", "name") }
  end

  # The sealed request is the only faithful record of what a step saw: the
  # user-role texts, and the paired results by call id.
  def request_payloads(agent_loop, key)
    ModelInvocation.find(node(agent_loop, key).selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |entry| entry.content_fragment.payload }
  end

  def request_texts(agent_loop, key)
    request_payloads(agent_loop, key).filter_map { |payload| payload.dig("parts", 0, "text") }
  end

  def paired_results(agent_loop, key)
    request_payloads(agent_loop, key).select { |payload| payload["type"] == "tool_result_item" }
      .to_h { |payload| [payload.dig("payload", "call_id"), payload.dig("payload", "output")] }
  end

  def envelope(task, status, prompt, text)
    "<task_result task=\"#{task}\" status=\"#{status}\">\n<prompt>#{prompt}</prompt>\n#{text}\n</task_result>"
  end

  test "a waited call places one branch the round's continuation waits on" do
    agent_loop = loop_with_round
    task_round!(agent_loop, { prompt: PROMPT }, wait: true)

    branch = node(agent_loop, "r1t0-model-1")
    assert_equal %w[branch absorb], [branch.continuation_source, branch.on_failure],
      "a model's task is a branch, and its failure reaches the model as an envelope"
    refute_predicate branch, :detached?
    assert_nil branch.input_from_node_keys, "a subagent starts from its brief: no history, no material"
    assert_equal %w[r1t0], sources_of(agent_loop, "r1t0-model-1")
    assert_equal PROMPT, branch.content_bodies.find_by(role: "input").effective_text
    assert_equal %w[read_file], tool_names(agent_loop, "r1t0-model-1"),
      "the round's surface minus the graph verbs: depth one"
    assert_equal "you are a kernel", branch.system_instructions
    assert_equal ["dev", "mock-text"], [branch.provider_id, branch.model_ref]

    assert_equal %w[r1t0 r1t0-model-1], sources_of(agent_loop, "r1"),
      "the continuation waits on the branch, not just on the call"
    assert_equal %w[round1 r1t0 r1t0-model-1], node(agent_loop, "r1").input_from_node_keys
    assert_equal "Task r1t0 started.\nTask reference: agent_loop=\"#{agent_loop.public_id}\", task=\"r1t0\".", tool_result(agent_loop, "r1t0"), "the WAITED answer"
    assert_equal "completed", node(agent_loop, "r1t0").status
  end

  # The branch calls a tool, so it grows a round of its own; the attach
  # follows its frontier and the consumer reads its last word — paired to
  # the call, in the call's place, never as a second message.
  test "the branch's final text lands as the call's paired result after a tool-using branch" do
    agent_loop = loop_with_round
    task_round!(agent_loop, { prompt: PROMPT }, wait: true)
    branch_calls!(agent_loop, "r1t0-model-1", "branching")

    assert_equal %w[r1t0 r1t0-model-1 r2], sources_of(agent_loop, "r1")
    assert_equal %w[round1 r1t0 r2], node(agent_loop, "r1").input_from_node_keys,
      "the read follows the frontier"

    settle_tool!(agent_loop, "r2t0", "the file")
    run!(agent_loop, "r2", "the answer")
    run!(agent_loop, "r1", "done")

    assert_equal envelope("r1t0", "completed", PROMPT.first(80), "Mock: the answer"),
      paired_results(agent_loop, "r1").fetch("call_0"),
      "the call's result IS the branch's answer, in the kernel's envelope; the prompt is bounded"
    texts = request_texts(agent_loop, "r1")
    assert_empty texts.grep(/Mock: the answer/), "the tip is not rendered twice"
    assert_empty texts.grep(/Mock: branching/), "the first round's chatter never reaches the consumer"
  end

  test "several waited calls in one message run at once and answer in call order" do
    agent_loop = loop_with_round
    task_round!(agent_loop, { prompt: "first job" }, { prompt: "second job" }, wait: true)

    assert_equal %w[r1t0 r1t0-model-1 r1t1 r1t1-model-1], sources_of(agent_loop, "r1")
    run!(agent_loop, "r1t1-model-1", "second done")
    run!(agent_loop, "r1t0-model-1", "first done")
    run!(agent_loop, "r1", "done")

    results = paired_results(agent_loop, "r1")
    assert_equal %w[call_0 call_1], results.keys, "results ride in the order the model asked"
    assert_equal envelope("r1t0", "completed", "first job", "Mock: first done"), results.fetch("call_0")
    assert_equal envelope("r1t1", "completed", "second job", "Mock: second done"), results.fetch("call_1")
  end

  # THE DEFAULT: a call without `wait: true` is detached — the branch hangs
  # off the call with no head to splice under, and the wake delivers it.
  test "a call without wait does not hold the round, and the wake delivers its answer" do
    agent_loop = loop_with_round
    task_round!(agent_loop, { prompt: "long test run" })

    branch = node(agent_loop, "r1t0-model-1")
    assert_predicate branch, :detached?
    assert_nil branch.input_from_node_keys
    assert_equal "branch", branch.continuation_source
    assert_equal %w[r1t0], sources_of(agent_loop, "r1"), "the continuation waits on the call alone"
    assert_equal %w[round1 r1t0], node(agent_loop, "r1").input_from_node_keys
    text = tool_result(agent_loop, "r1t0")
    assert_match(/\ATask r1t0 started in the background\. Its <task_result task="r1t0"> reaches you/, text)
    assert_match(/in this loop before it completes/, text)

    run!(agent_loop, "r1t0-model-1", "all green")
    run!(agent_loop, "r1", "meanwhile")
    assert_empty request_texts(agent_loop, "r1").grep(/all green/),
      "a running round's request is sealed; nothing is delivered early"

    wake = node(agent_loop, "w1")
    assert_equal %w[r1 r1t0-model-1], wake.input_from_node_keys
    schedule!(agent_loop)
    assert_includes request_texts(agent_loop, "w1"),
      envelope("r1t0", "completed", "long test run", "Mock: all green"),
      "the wake reads the tip as a message that is not from the person"
  end

  # THE IMMEDIATE ANSWERS: the default answers with the started id and the background sentence —
  # and `wait: true` answers with "Task <id>
  # started."; `wait: false` spells the default. Only the waited branch is spliced under the head.
  test "the immediate answer names the word: the default's background sentence, wait: true's started" do
    agent_loop = loop_with_round
    task_round!(agent_loop, { prompt: "now", wait: true }, { prompt: "later" }, { prompt: "spelled", wait: false })

    assert_equal "Task r1t0 started.\nTask reference: agent_loop=\"#{agent_loop.public_id}\", task=\"r1t0\".", tool_result(agent_loop, "r1t0")
    background = "Task r1t1 started in the background. Its <task_result task=\"r1t1\"> reaches you " \
      "in this loop before it completes. Continue other work while it runs.\n" \
      "Task reference: agent_loop=\"#{agent_loop.public_id}\", task=\"r1t1\"."
    assert_equal background, tool_result(agent_loop, "r1t1")
    assert_equal background.gsub("r1t1", "r1t2"), tool_result(agent_loop, "r1t2")
    assert_equal [false, true, true], %w[r1t0 r1t1 r1t2].map { |key| node(agent_loop, "#{key}-model-1").detached? }
    assert_equal %w[r1t0 r1t0-model-1 r1t1 r1t2], sources_of(agent_loop, "r1"),
      "the continuation waits on the waited branch and on every call, never on a detached branch"
    assert_equal %w[round1 r1t0 r1t1 r1t2 r1t0-model-1], node(agent_loop, "r1").input_from_node_keys,
      "the fan, then the one splice"
  end

  # THE ALIAS THROUGH THE REAL DISPATCH: `Agent` is `task` under the claude preset's spelling —
  # `run_in_background: false` waits, the default is detached — and the immediate answers are the
  # kernel's own (they name the task key, never the tool).
  def aliased_loop
    agent_loop = seed(model("round1", "prompt" => "do the work",
      "tools" => [LoopLaneTestHelper::AGENT_ALIAS, Nexus::Compose::DEFINITION, READ_FILE]))
    start!(agent_loop)
    agent_loop
  end

  def agent_round!(agent_loop, *calls, key: "round1")
    tool_calls = calls.each_with_index.map do |arguments, index|
      { id: "call_#{index}", name: "Agent", arguments: arguments.to_json }
    end
    apply_via(step_attempt(agent_loop, key), sse_success("delegating", tool_calls: tool_calls))
    AgentLoops::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ScheduleJob]) do
      schedule!(agent_loop)
    end
    agent_loop.reload
  end

  test "an Agent call waits with run_in_background false and is detached by default" do
    agent_loop = aliased_loop
    agent_round!(agent_loop, { prompt: "now", run_in_background: false }, { prompt: "later" })

    assert_equal %w[task task], %w[r1t0 r1t1].map { |key| node(agent_loop, key).tool_name }
    assert_equal %w[Agent Agent], %w[r1t0 r1t1].map { |key| node(agent_loop, key).tool_alias }
    assert_equal "Task r1t0 started.\nTask reference: agent_loop=\"#{agent_loop.public_id}\", task=\"r1t0\".", tool_result(agent_loop, "r1t0")
    assert_match(/\ATask r1t1 started in the background\./, tool_result(agent_loop, "r1t1"))
    assert_equal [false, true], %w[r1t0 r1t1].map { |key| node(agent_loop, "#{key}-model-1").detached? }
    assert_equal %w[r1t0 r1t0-model-1 r1t1], sources_of(agent_loop, "r1")
    assert_equal %w[read_file], tool_names(agent_loop, "r1t0-model-1"),
      "the branch inherits the round's surface minus the graph verbs, the alias included"
  end

  # THE BRANCH'S OWN RENDER: `spawn`'s text cites `{{task}}`, which the
  # round spells `Agent` under the claude preset; a branch withholds
  # `Agent`, so the inherited entry is re-rendered in the branch's own
  # names — the bytes compile's `kernel_tool_redefined` check expects.
  test "a branch re-renders an inherited kernel tool whose text cites the withheld alias" do
    spawn = Nexus::ToolRegistry.function_definition("nexus.conversation.spawn")
    agent_loop = seed(model("round1", "prompt" => "do the work",
      "tools" => [LoopLaneTestHelper::AGENT_ALIAS, Nexus::Compose::DEFINITION, spawn, READ_FILE]))
    start!(agent_loop)
    assert_includes node(agent_loop, "round1").tool_definitions.find { |d| d.dig("function", "name") == "spawn" }
      .dig("function", "description"), "`Agent`", "the round's spawn names the alias"

    agent_round!(agent_loop, { prompt: "now", run_in_background: false })

    assert_equal "Task r1t0 started.\nTask reference: agent_loop=\"#{agent_loop.public_id}\", task=\"r1t0\".", tool_result(agent_loop, "r1t0")
    assert_equal %w[read_file spawn], tool_names(agent_loop, "r1t0-model-1"),
      "the branch inherits spawn and read_file, never the alias nor compose"
    description = node(agent_loop, "r1t0-model-1").tool_definitions
      .find { |d| d.dig("function", "name") == "spawn" }.dig("function", "description")
    assert_includes description, "`task`", "re-spelled in the branch's own names"
    refute_includes description, "Agent", "the withheld alias is cited nowhere"
  end

  test "a rule on task matches a call made as Agent at the approval stage" do
    agent_loop = seed(model("round1", "prompt" => "do the work",
      "tools" => [LoopLaneTestHelper::AGENT_ALIAS, READ_FILE]),
      approval_mode: "bypass", approval_rules: [{ "tool" => "task", "verdict" => "deny", "reason" => "no jobs today" }])
    start!(agent_loop)
    agent_round!(agent_loop, { prompt: "go" })

    call = node(agent_loop, "r1t0")
    assert_equal ["failed", "approval_denied", "no jobs today"], [call.status, call.error_key, call.error_detail]
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "r1t0-model-1"), "denied before any dispatch"
  end

  test "tools narrows to names the round offers; a name it lacks is refused with the right ones" do
    agent_loop = loop_with_round
    task_round!(agent_loop, { prompt: "read only", tools: ["read_file"] }, { prompt: "go", tools: ["browse"] },
      wait: true)

    assert_equal %w[read_file], tool_names(agent_loop, "r1t0-model-1")
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "r1t1-model-1"), "a refused call places nothing"
    refused = node(agent_loop, "r1t1")
    assert_equal "completed", refused.status, "a refusal RAN: it is data the round reads"
    assert refused.output_summary["is_error"]
    assert_equal 'tools: "browse" is not one of your tools. You have: compose, read_file, task',
      tool_result(agent_loop, "r1t1")
    assert_equal %w[r1t0 r1t0-model-1 r1t1], sources_of(agent_loop, "r1")
  end

  test "the graph verbs are withheld from a branch even by name, nor by alias" do
    agent_loop = loop_with_round
    task_round!(agent_loop, { prompt: "spawn more", tools: ["task"] })

    assert_equal 'tools: "task" is not one of your tools. You have: compose, read_file, task',
      tool_result(agent_loop, "r1t0")

    aliased = aliased_loop
    agent_round!(aliased, { prompt: "spawn more", tools: ["Agent"] })
    assert_equal 'tools: "Agent" is not one of your tools. You have: Agent, compose, read_file',
      tool_result(aliased, "r1t0"), "withheld by canonical: a branch never inherits the alias either"
  end

  test "an empty prompt and a wait that is not a boolean are refused by sentence" do
    agent_loop = loop_with_round
    task_round!(agent_loop, { prompt: "  " }, { prompt: "go", wait: "yes" })

    assert_equal AgentLoops::TaskTool::Run::EMPTY_PROMPT, tool_result(agent_loop, "r1t0")
    assert_equal AgentLoops::TaskTool::Run::INVALID_WAIT, tool_result(agent_loop, "r1t1")
    assert_equal "wait must be true or false.", AgentLoops::TaskTool::Run::INVALID_WAIT
    assert %w[r1t0 r1t1].all? { |key| node(agent_loop, key).output_summary["is_error"] }
    refute_predicate node(agent_loop, "r1"), :terminal?, "one bad call never fails the round"
  end

  # Request hygiene, not a ceiling: the continuation reads the spine, every
  # call and every blocking branch, and the read list is bounded.
  test "past 128 waited calls a splice is refused too_many_reads and the round continues" do
    agent_loop = loop_with_round
    task_round!(agent_loop, *Array.new(129) { |index| { prompt: "job #{index}" } }, wait: true)

    branches = agent_loop.agent_loop_nodes.where("node_key LIKE '%-model-1'").count
    assert_operator branches, :<, 129
    refused = agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ToolTask.sti_name)
      .select { |call| call.output_summary&.dig("is_error") }
    refute_empty refused
    assert_equal "The task was refused: too_many_reads.",
      refused.first.content_bodies.find_by(role: "output").effective_text
    assert_equal AgentLoops::Tasks::Compile::KERNEL_MAX_INPUT_FROM,
      node(agent_loop, "r1").input_from_node_keys.length
    assert_equal "queued", node(agent_loop, "r1").status
  end
end
