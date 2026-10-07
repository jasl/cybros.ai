require "test_helper"

# `task` — one bounded job to a new agent with an EMPTY context. The call is an ordinary fan member;
# its executor places ONE model step through the shared task append door, marked `branch`, `absorb`,
# carrying the round's surface with optional narrowing. The WHEN word is `wait` on the call: by
# default the branch is detached, the continuation runs on and the wake delivers the answer later as
# a `<task_result>` message; with `wait: true` the round's continuation waits on the branch and its
# last word is the CALL's paired result.
class AgentRuns::DelegateTaskToolTest < ActiveJob::TestCase
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
    super(key, "tools" => [Nexus::Tools::DELEGATE_TASK, Nexus::ToolRegistry.function_definition("wait"), READ_FILE], **over)
  end

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def schedule!(agent_run) = AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def step_attempt(agent_run, key)
    invocation_id = node(agent_run, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def loop_with_round
    agent_run = seed(model("round1", "prompt" => "do the work", "instructions" => "you are a kernel"))
    start!(agent_run)
    agent_run
  end

  # A round that answers with `task` calls, driven through the scheduler,
  # the dispatch and the job. Each argument hash is one call, in order;
  # `wait:` is the CALL's word, given to every call of the round when set
  # (absent, the default: the branch is detached).
  def task_round!(agent_run, *calls, key: "round1", wait: nil)
    tool_calls = calls.each_with_index.map do |arguments, index|
      arguments = arguments.merge(wait: wait) unless wait.nil?
      { id: "call_#{index}", name: "delegate_task", arguments: arguments.to_json }
    end
    apply_via(step_attempt(agent_run, key), sse_success("delegating", tool_calls: tool_calls))
    AgentRuns::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::ScheduleJob]) do
      schedule!(agent_run)
    end
    agent_run.reload
  end

  def run!(agent_run, key, text)
    apply_via(step_attempt(agent_run, key), sse_success(text))
    AgentRuns::ConvergeTerminalSteps.call
    schedule!(agent_run)
  end

  # The branch answers with one tool call, so the driver expands it.
  def branch_calls!(agent_run, key, text)
    apply_via(step_attempt(agent_run, key), sse_success(text, tool_calls: [
      { id: "call_#{key}", name: "read_file", arguments: '{"path":"a"}' },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    schedule!(agent_run)
  end

  def settle_tool!(agent_run, key, text)
    AgentRuns::Parks::Settle.call(node: node(agent_run, key), trusted: true,
      content: text, outcome: "completed")
    schedule!(agent_run)
  end

  def sources_of(agent_run, key)
    node(agent_run, key).incoming_edges.includes(:from_node).map { |edge| edge.from_node.node_key }.sort
  end

  def tool_result(agent_run, key) = node(agent_run, key).content_bodies.find_by(role: "output")&.effective_text

  def tool_names(agent_run, key)
    Array(node(agent_run, key).tool_definitions).map { |definition| definition.dig("function", "name") }
  end

  # The sealed request is the only faithful record of what a step saw: the
  # user-role texts, and the paired results by call id.
  def request_payloads(agent_run, key)
    ModelInvocation.find(node(agent_run, key).selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |entry| entry.content_fragment.payload }
  end

  def request_texts(agent_run, key)
    request_payloads(agent_run, key).filter_map { |payload| payload.dig("parts", 0, "text") }
  end

  def paired_results(agent_run, key)
    request_payloads(agent_run, key).select { |payload| payload["type"] == "tool_result_item" }
      .to_h { |payload| [payload.dig("payload", "call_id"), payload.dig("payload", "output")] }
  end

  def envelope(task, status, prompt, text, model: nil)
    ["<task_result task=\"#{task}\" status=\"#{status}\">", "<prompt>#{prompt}</prompt>",
      ("Requested model: #{model}; actual model: #{model}." if model), text, "</task_result>"].compact.join("\n")
  end

  test "a waited call places one branch the round's continuation waits on" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: PROMPT }, wait: true)

    branch = node(agent_run, "r1t0-model-1")
    assert_equal %w[branch absorb], [branch.continuation_source, branch.on_failure],
      "a model's task is a branch, and its failure reaches the model as an envelope"
    refute_predicate branch, :detached?
    assert_nil branch.input_from_node_keys, "a subagent starts from its brief: no history, no material"
    assert_equal %w[r1t0], sources_of(agent_run, "r1t0-model-1")
    assert_equal PROMPT, branch.content_bodies.find_by(role: "input").effective_text
    assert_equal %w[delegate_task read_file wait], tool_names(agent_run, "r1t0-model-1"),
      "the branch inherits the declared delegation tool"
    assert_equal "you are a kernel", branch.system_instructions
    assert_equal ["dev", "mock-text"], [branch.provider_id, branch.model_ref]

    assert_equal %w[r1t0 r1t0-model-1], sources_of(agent_run, "r1"),
      "the continuation waits on the branch, not just on the call"
    assert_equal %w[round1 r1t0 r1t0-model-1], node(agent_run, "r1").input_from_node_keys
    assert_equal "Task r1t0 started.\nTask reference: run_public_id=\"#{agent_run.public_id}\", task=\"r1t0\".", tool_result(agent_run, "r1t0"), "the WAITED answer"
    assert_equal "completed", node(agent_run, "r1t0").status
  end

  # The branch calls a tool, so it grows a round of its own; the attach
  # follows its frontier and the consumer reads its last word — paired to
  # the call, in the call's place, never as a second message.
  test "the branch's final text lands as the call's paired result after a tool-using branch" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: PROMPT }, wait: true)
    branch_calls!(agent_run, "r1t0-model-1", "branching")

    assert_equal %w[r1t0 r1t0-model-1 r2], sources_of(agent_run, "r1")
    assert_equal %w[round1 r1t0 r2], node(agent_run, "r1").input_from_node_keys,
      "the read follows the frontier"

    settle_tool!(agent_run, "r2t0", "the file")
    run!(agent_run, "r2", "the answer")
    run!(agent_run, "r1", "done")

    assert_equal envelope("r1t0", "completed", PROMPT.first(80), "Mock: the answer"),
      paired_results(agent_run, "r1").fetch("call_0"),
      "the call's result IS the branch's answer, in the kernel's envelope; the prompt is bounded"
    texts = request_texts(agent_run, "r1")
    assert_empty texts.grep(/Mock: the answer/), "the tip is not rendered twice"
    assert_empty texts.grep(/Mock: branching/), "the first round's chatter never reaches the consumer"
  end

  test "several waited calls in one message run at once and answer in call order" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: "first job" }, { prompt: "second job" }, wait: true)

    assert_equal %w[r1t0 r1t0-model-1 r1t1 r1t1-model-1], sources_of(agent_run, "r1")
    run!(agent_run, "r1t1-model-1", "second done")
    run!(agent_run, "r1t0-model-1", "first done")
    run!(agent_run, "r1", "done")

    results = paired_results(agent_run, "r1")
    assert_equal %w[call_0 call_1], results.keys, "results ride in the order the model asked"
    assert_equal envelope("r1t0", "completed", "first job", "Mock: first done"), results.fetch("call_0")
    assert_equal envelope("r1t1", "completed", "second job", "Mock: second done"), results.fetch("call_1")
  end

  # THE DEFAULT: a call without `wait: true` is detached — the branch hangs
  # off the call with no head to splice under, and the wake delivers it.
  test "a call without wait does not hold the round, and the wake delivers its answer" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: "long test run" })

    branch = node(agent_run, "r1t0-model-1")
    assert_predicate branch, :detached?
    assert_nil branch.input_from_node_keys
    assert_equal "branch", branch.continuation_source
    assert_equal %w[r1t0], sources_of(agent_run, "r1"), "the continuation waits on the call alone"
    assert_equal %w[round1 r1t0], node(agent_run, "r1").input_from_node_keys
    text = tool_result(agent_run, "r1t0")
    assert_match(/\ATask r1t0 started in the background\. Its <task_result task="r1t0"> reaches you/, text)
    assert_match(/in this loop before it completes/, text)

    run!(agent_run, "r1t0-model-1", "all green")
    run!(agent_run, "r1", "meanwhile")
    assert_empty request_texts(agent_run, "r1").grep(/all green/),
      "a running round's request is sealed; nothing is delivered early"

    wake = node(agent_run, "w1")
    assert_equal %w[r1 r1t0-model-1], wake.input_from_node_keys
    schedule!(agent_run)
    assert_includes request_texts(agent_run, "w1"),
      envelope("r1t0", "completed", "long test run", "Mock: all green"),
      "the wake reads the tip as a message that is not from the person"
  end

  # THE IMMEDIATE ANSWERS: the default answers with the started id and the background sentence —
  # and `wait: true` answers with "Task <id>
  # started."; `wait: false` spells the default. Only the waited branch is spliced under the head.
  test "the immediate answer names the word: the default's background sentence, wait: true's started" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: "now", wait: true }, { prompt: "later" }, { prompt: "spelled", wait: false })

    assert_equal "Task r1t0 started.\nTask reference: run_public_id=\"#{agent_run.public_id}\", task=\"r1t0\".", tool_result(agent_run, "r1t0")
    background = "Task r1t1 started in the background. Its <task_result task=\"r1t1\"> reaches you " \
      "in this loop before it completes. Continue other work while it runs.\n" \
      "Task reference: run_public_id=\"#{agent_run.public_id}\", task=\"r1t1\"."
    assert_equal background, tool_result(agent_run, "r1t1")
    assert_equal background.gsub("r1t1", "r1t2"), tool_result(agent_run, "r1t2")
    assert_equal [false, true, true], %w[r1t0 r1t1 r1t2].map { |key| node(agent_run, "#{key}-model-1").detached? }
    assert_equal %w[r1t0 r1t0-model-1 r1t1 r1t2], sources_of(agent_run, "r1"),
      "the continuation waits on the waited branch and on every call, never on a detached branch"
    assert_equal %w[round1 r1t0 r1t1 r1t2 r1t0-model-1], node(agent_run, "r1").input_from_node_keys,
      "the fan, then the one splice"
  end

  # THE ALIAS THROUGH THE REAL DISPATCH: `Agent` is `task` under the claude preset's spelling —
  # `run_in_background: false` waits, the default is detached — and the immediate answers are the
  # kernel's own (they name the task key, never the tool).
  def aliased_loop
    agent_run = seed(model("round1", "prompt" => "do the work",
      "tools" => [RunLaneTestHelper::AGENT_ALIAS, Nexus::ToolRegistry.function_definition("wait"), READ_FILE]))
    start!(agent_run)
    agent_run
  end

  def agent_round!(agent_run, *calls, key: "round1")
    tool_calls = calls.each_with_index.map do |arguments, index|
      { id: "call_#{index}", name: "Agent", arguments: arguments.to_json }
    end
    apply_via(step_attempt(agent_run, key), sse_success("delegating", tool_calls: tool_calls))
    AgentRuns::ConvergeTerminalSteps.call
    perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::ScheduleJob]) do
      schedule!(agent_run)
    end
    agent_run.reload
  end

  test "an Agent call waits with run_in_background false and is detached by default" do
    agent_run = aliased_loop
    agent_round!(agent_run, { prompt: "now", run_in_background: false }, { prompt: "later" })

    assert_equal %w[delegate_task delegate_task], %w[r1t0 r1t1].map { |key| node(agent_run, key).tool_name }
    assert_equal %w[Agent Agent], %w[r1t0 r1t1].map { |key| node(agent_run, key).tool_alias }
    assert_equal "Task r1t0 started.\nTask reference: run_public_id=\"#{agent_run.public_id}\", task=\"r1t0\".", tool_result(agent_run, "r1t0")
    assert_match(/\ATask r1t1 started in the background\./, tool_result(agent_run, "r1t1"))
    assert_equal [false, true], %w[r1t0 r1t1].map { |key| node(agent_run, "#{key}-model-1").detached? }
    assert_equal %w[r1t0 r1t0-model-1 r1t1], sources_of(agent_run, "r1")
    assert_equal %w[Agent read_file wait], tool_names(agent_run, "r1t0-model-1"),
      "the branch inherits the delegation tool under its declared alias"
  end

  # THE BRANCH'S OWN RENDER: `spawn`'s text cites `{{delegate_task}}`, which the
  # round spells `Agent` under the claude preset; explicit narrowing removes
  # `Agent`, so the inherited entry is re-rendered in the branch's own
  # names — the bytes compile's `kernel_tool_redefined` check expects.
  test "a branch re-renders an inherited kernel tool whose text cites a narrowed-away alias" do
    spawn = Nexus::ToolRegistry.function_definition("nexus.conversation.spawn")
    agent_run = seed(model("round1", "prompt" => "do the work",
      "tools" => [RunLaneTestHelper::AGENT_ALIAS, Nexus::ToolRegistry.function_definition("wait"), spawn, READ_FILE]))
    start!(agent_run)
    assert_includes node(agent_run, "round1").tool_definitions.find { |d| d.dig("function", "name") == "spawn" }
      .dig("function", "description"), "`Agent`", "the round's spawn names the alias"

    agent_round!(agent_run, { prompt: "now", run_in_background: false, tools: %w[read_file spawn wait] })

    assert_equal "Task r1t0 started.\nTask reference: run_public_id=\"#{agent_run.public_id}\", task=\"r1t0\".", tool_result(agent_run, "r1t0")
    assert_equal %w[read_file spawn wait], tool_names(agent_run, "r1t0-model-1"),
      "explicit narrowing retains spawn and read_file but removes the task alias"
    description = node(agent_run, "r1t0-model-1").tool_definitions
      .find { |d| d.dig("function", "name") == "spawn" }.dig("function", "description")
    assert_includes description, "`delegate_task`", "re-spelled in the branch's own names"
    refute_includes description, "Agent", "the removed alias is cited nowhere"
  end

  test "a rule on task matches a call made as Agent at the approval stage" do
    agent_run = seed(model("round1", "prompt" => "do the work",
      "tools" => [RunLaneTestHelper::AGENT_ALIAS, READ_FILE]),
      approval_mode: "bypass", approval_rules: [{ "tool" => "delegate_task", "verdict" => "deny", "reason" => "no jobs today" }])
    start!(agent_run)
    agent_round!(agent_run, { prompt: "go" })

    call = node(agent_run, "r1t0")
    assert_equal ["failed", "approval_denied", "no jobs today"], [call.status, call.error_key, call.error_detail]
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "r1t0-model-1"), "denied before any dispatch"
  end

  test "tools narrows to names the round offers; a name it lacks is refused with the right ones" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: "read only", tools: ["read_file"] }, { prompt: "go", tools: ["browse"] },
      wait: true)

    assert_equal %w[read_file], tool_names(agent_run, "r1t0-model-1")
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "r1t1-model-1"), "a refused call places nothing"
    refused = node(agent_run, "r1t1")
    assert_equal "completed", refused.status, "a refusal RAN: it is data the round reads"
    assert refused.output_summary["is_error"]
    assert_equal 'tools: "browse" is not one of your tools. You have: delegate_task, read_file, wait',
      tool_result(agent_run, "r1t1")
    assert_equal %w[r1t0 r1t0-model-1 r1t1], sources_of(agent_run, "r1")
  end

  test "a branch may explicitly retain delegation by name or alias" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: "spawn more", tools: ["delegate_task"] })

    assert_equal %w[delegate_task], tool_names(agent_run, "r1t0-model-1")

    aliased = aliased_loop
    agent_round!(aliased, { prompt: "spawn more", tools: ["Agent"] })
    assert_equal %w[Agent], tool_names(aliased, "r1t0-model-1")
  end

  test "sequential implementation and review use distinct models and hand off a persisted patch" do
    agent = users(:agent)
    agent.update!(default_model: "dev/mock-text")
    profile = agent.attributes
    write = { "type" => "function",
              "function" => { "name" => "write_file", "parameters" => { "type" => "object" } } }
    agent_run = seed(model("round1", "prompt" => "implement then review",
      "tools" => [Nexus::Tools::DELEGATE_TASK, READ_FILE, write]), creating_user: agent)
    start!(agent_run)
    task_round!(agent_run, { prompt: "implement the fix and return its patch", model: "dev/mock-unmetered" }, wait: true)
    implementation = node(agent_run, "r1t0-model-1")
    assert_equal "mock-unmetered", implementation.selected_model_invocation.model_ref
    patch = "diff --git a/app/example.rb b/app/example.rb\n-accepted = false\n+accepted = true\n"
    apply_via(step_attempt(agent_run, implementation.node_key), sse_success("implementing", tool_calls: [
      { id: "write_patch", name: "write_file", arguments: { path: "patch.diff", content: patch }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    schedule!(agent_run)
    writer = agent_run.agent_run_tasks.find_by!(tool_call_id: "write_patch")
    assert_equal "queued", node(agent_run, "r1").status
    assert_nil node(agent_run, "r1").selected_model_invocation_id
    assert_not agent_run.model_invocations.exists?(model_ref: "mock-windowless")

    capture = @account.content_uploads.create!(creating_user: agent,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(patch), filename: "patch.diff",
        content_type: "text/plain", identify: false))
    uri = "nexus://uploads/#{capture.public_id}"
    assert_predicate AgentRuns::Parks::Settle.call(node: writer, trusted: true, creator: agent, content: [
      { "type" => "text", "text" => "patch.diff written" },
      { "type" => "resource_link", "uri" => uri, "name" => "patch.diff" },
    ]), :applied?
    schedule!(agent_run)
    assert_equal [capture.id], writer.reload.output_body.content_uploads.pluck(:id)
    assert_equal "queued", node(agent_run, "r1").status, "review cannot start before the implementation's final answer"
    run!(agent_run, "r2", "Implemented app/example.rb; patch: #{uri}")
    implementation_result = paired_results(agent_run, "r1").fetch("call_0")
    assert_includes implementation_result, "Mock: Implemented app/example.rb"
    assert_includes implementation_result, uri

    brief = "Review this implementation result and its patch:\n#{implementation_result}"
    task_round!(agent_run, { prompt: brief, model: "dev/mock-windowless", tools: ["read_file"] }, key: "r1", wait: true)
    reviewer = node(agent_run, "r3t0-model-1")
    assert_equal "mock-windowless", reviewer.selected_model_invocation.model_ref
    assert_includes request_texts(agent_run, reviewer.node_key), brief
    assert_equal "mock-text", node(agent_run, "r1").selected_model_invocation.model_ref
    apply_via(step_attempt(agent_run, reviewer.node_key), sse_success("reading the patch", tool_calls: [
      { id: "read_patch", name: "read_file", arguments: { path: uri }.to_json },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    schedule!(agent_run)
    reader = agent_run.agent_run_tasks.find_by!(tool_call_id: "read_patch")
    assert_equal uri, reader.tool_input.fetch("path")
    artifact = Executors::Attachments.fetch(agent_run: reader.agent_run, public_id: capture.public_id)
    assert_equal patch, artifact.file.download
    settle_tool!(agent_run, reader.node_key, artifact.file.download)
    assert_equal patch, paired_results(agent_run, "r4").fetch("read_patch")
    assert_equal "mock-windowless", node(agent_run, "r4").selected_model_invocation.model_ref
    run!(agent_run, "r4", "Reviewed patch.diff: the fix is correct")
    assert_includes paired_results(agent_run, "r3").fetch("call_0"), "Mock: Reviewed patch.diff: the fix is correct"
    assert_equal "mock-text", node(agent_run, "r3").selected_model_invocation.model_ref
    assert_equal "mock-text", node(agent_run, "round1").model_ref
    assert_equal profile, agent.reload.attributes
    run!(agent_run, "r3", "reported implementation and review")
    assert_equal "completed", agent_run.reload.status
  end

  test "three agent levels execute on their selected models and return final results to each parent" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: "implement", model: "dev/mock-unmetered" }, wait: true)
    child = node(agent_run, "r1t0-model-1")
    assert_equal "mock-unmetered", child.selected_model_invocation.model_ref

    task_round!(agent_run, { prompt: "verify implementation", model: "dev/mock-windowless" },
      key: child.node_key, wait: true)
    grandchild = node(agent_run, "r2t0-model-1")
    assert_equal "mock-windowless", grandchild.selected_model_invocation.model_ref
    assert_equal "queued", node(agent_run, "r1").status
    assert_equal "queued", node(agent_run, "r2").status

    run!(agent_run, grandchild.node_key, "checks passed: app/example.rb")
    assert_equal envelope("r2t0", "completed", "verify implementation", "Mock: checks passed: app/example.rb",
      model: "dev/mock-windowless"),
      paired_results(agent_run, "r2").fetch("call_0")
    assert_equal "mock-unmetered", node(agent_run, "r2").selected_model_invocation.model_ref
    assert_equal "queued", node(agent_run, "r1").status, "the main agent waits for the child's synthesis"

    run!(agent_run, "r2", "implemented app/example.rb; checks passed")
    assert_equal envelope("r1t0", "completed", "implement", "Mock: implemented app/example.rb; checks passed",
      model: "dev/mock-unmetered"),
      paired_results(agent_run, "r1").fetch("call_0")
    assert_equal "mock-text", node(agent_run, "r1").selected_model_invocation.model_ref
    assert_equal "mock-text", node(agent_run, "round1").model_ref
    run!(agent_run, "r1", "reported")
    assert_equal "completed", agent_run.reload.status
  end

  test "force Stop cancels a running third-level model and both waiting parents" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: "implement", model: "dev/mock-unmetered" }, wait: true)
    task_round!(agent_run, { prompt: "long verification", model: "dev/mock-windowless" },
      key: "r1t0-model-1", wait: true)
    grandchild = node(agent_run, "r2t0-model-1")
    attempt = step_attempt(agent_run, grandchild.node_key)
    start(attempt)

    stopped = AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: true))
    assert_predicate stopped, :accepted?
    AgentRuns::ConvergeTerminalSteps.call
    schedule!(agent_run)

    assert_equal "canceled", grandchild.selected_model_invocation.reload.status
    assert_equal %w[canceled canceled canceled], %w[r1 r2 r2t0-model-1].map { |key| node(agent_run, key).status }
    assert_equal "canceled", agent_run.reload.status
    assert agent_run.agent_run_tasks.all?(&:terminal?)
    assert_nil node(agent_run, "r1").selected_model_invocation_id
    assert_nil node(agent_run, "r2").selected_model_invocation_id
  end

  test "nested delegation without a model inherits the immediate parent's configured model" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: "implement", model: "dev/mock-unmetered" }, wait: true)
    task_round!(agent_run, { prompt: "verify" }, key: "r1t0-model-1", wait: true)

    assert_equal "mock-unmetered", node(agent_run, "r2t0-model-1").selected_model_invocation.model_ref
    assert_equal "mock-text", node(agent_run, "round1").model_ref
    assert_equal "mock-text", node(agent_run, "r1").model_ref
  end

  test "a canceled explicit delegate that never starts does not claim an executed model" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: "review", model: "dev/mock-unmetered" }, wait: true)
    stopped = AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: true))
    assert_predicate stopped, :accepted?
    AgentRuns::ConvergeTerminalSteps.call

    result = AgentRuns::TaskResultEnvelope.for(node(agent_run, "r1t0-model-1"))
    assert_includes result, "Requested model: dev/mock-unmetered; actual model: not started."
    assert_includes result, 'status="canceled"'
  end

  test "an unavailable explicit model is refused without inheriting the caller model" do
    agent_run = loop_with_round
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    policy.set_model_availability("dev/mock-unmetered", available: false)
    policy.save!
    task_round!(agent_run, { prompt: "review", model: "dev/mock-unmetered" }, wait: true)

    assert_nil agent_run.agent_run_tasks.find_by(node_key: "r1t0-model-1")
    assert node(agent_run, "r1t0").output_summary.fetch("is_error")
    assert_includes tool_result(agent_run, "r1t0"), "model_not_authorized"
    assert_includes tool_result(agent_run, "r1t0"), "dev/mock-unmetered"
    assert_equal "mock-text", node(agent_run, "r1").selected_model_invocation.model_ref
    assert_equal %w[mock-text], agent_run.model_invocations.distinct.pluck(:model_ref)
  end

  test "an explicit delegated model's fallback result names the requested and actual models" do
    agent = users(:agent)
    agent.update!(fallback_model: "dev/mock-windowless")
    agent_run = seed(model("round1", "prompt" => "coordinate"), creating_user: agent)
    start!(agent_run)
    task_round!(agent_run, { prompt: "review", model: "dev/mock-unmetered" }, wait: true)
    apply_via(step_attempt(agent_run, "r1t0-model-1"), sse_refused("cannot review this"))
    AgentRuns::ConvergeTerminalSteps.call
    schedule!(agent_run)
    branch = node(agent_run, "r1t0-model-1")
    assert_equal "mock-windowless", branch.selected_model_invocation.model_ref
    assert_equal({ "from" => "dev/mock-unmetered", "reason" => "model_refused" },
      branch.output_summary.fetch("model_change"))

    branch_calls!(agent_run, branch.node_key, "reading changes")
    settle_tool!(agent_run, "r2t0", "source diff")
    tool_envelope = AgentRuns::TaskResultEnvelope.for(node(agent_run, "r2t0"))
    assert_includes tool_envelope, "Requested model: dev/mock-unmetered; actual model: dev/mock-windowless."
    assert_includes tool_envelope, "<call>read_file", "the tool keeps its own result attribution"
    run!(agent_run, "r2", "review complete")

    result = paired_results(agent_run, "r1").fetch("call_0")
    assert_includes result, "Requested model: dev/mock-unmetered; actual model: dev/mock-windowless."
    assert_includes result, "Mock: review complete"
    assert_equal "mock-text", node(agent_run, "r1").selected_model_invocation.model_ref
    assert_equal "dev/mock-windowless", agent.reload.fallback_model
  end

  test "a narrowed branch cannot invoke an undeclared delegation tool" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: "read only", tools: ["read_file"] }, wait: true)
    task_round!(agent_run, { prompt: "guess delegation" }, key: "r1t0-model-1", wait: true)

    assert_nil agent_run.agent_run_tasks.find_by(node_key: "r2t0-model-1")
    refused = node(agent_run, "r2t0")
    assert_equal "failed", refused.status
    assert_equal "unknown_tool", refused.error_key
  end

  test "an empty prompt and a wait that is not a boolean are refused by sentence" do
    agent_run = loop_with_round
    task_round!(agent_run, { prompt: "  " }, { prompt: "go", wait: "yes" })

    assert_equal AgentRuns::DelegateTaskTool::Run::EMPTY_PROMPT, tool_result(agent_run, "r1t0")
    assert_equal AgentRuns::DelegateTaskTool::Run::INVALID_WAIT, tool_result(agent_run, "r1t1")
    assert_equal "wait must be true or false.", AgentRuns::DelegateTaskTool::Run::INVALID_WAIT
    assert %w[r1t0 r1t1].all? { |key| node(agent_run, key).output_summary["is_error"] }
    refute_predicate node(agent_run, "r1"), :terminal?, "one bad call never fails the round"
  end

  # Request hygiene, not a ceiling: the continuation reads the mainline, every
  # call and every blocking branch, and the read list is bounded.
  test "past 128 waited calls a splice is refused too_many_reads and the round continues" do
    agent_run = loop_with_round
    task_round!(agent_run, *Array.new(129) { |index| { prompt: "job #{index}" } }, wait: true)

    branches = agent_run.agent_run_tasks.where("node_key LIKE '%-model-1'").count
    assert_operator branches, :<, 129
    refused = agent_run.agent_run_tasks.where(type: AgentRunTasks::ToolTask.sti_name)
      .select { |call| call.output_summary&.dig("is_error") }
    refute_empty refused
    assert_equal "The task was refused: too_many_reads.",
      refused.first.content_bodies.find_by(role: "output").effective_text
    assert_equal AgentRuns::Tasks::Compile::KERNEL_MAX_INPUT_FROM,
      node(agent_run, "r1").input_from_node_keys.length
    assert_equal "queued", node(agent_run, "r1").status
  end
end
