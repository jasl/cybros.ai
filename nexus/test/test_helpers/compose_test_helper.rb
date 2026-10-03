# THE COMPOSE LANE IN TESTS: a loop whose round answers with one `compose` call, driven through the
# scheduler, the compose job and admission as the product drives them, and the reads a case pins —
# what a node waits on, what a continuation reads, what a step's sealed request carried. Shared by
# the attached and the detached compose suites; an includer carries InvocationHarness and
# ActiveJob::TestHelper (the rounds enqueue) and sets @human, @workspace and the dev lane.
module ComposeTestHelper
  def model(key, **over) = super(key, "tools" => [Nexus::Compose::DEFINITION], **over)

  def compile(steps) = AgentLoops::Tasks::Compile.call(steps, AgentLoops::Tasks::Tip.seed("round"))

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    clear_enqueued_jobs
    schedule!(agent_loop)
  end

  def schedule!(agent_loop)
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  # The attempt is looked up rather than memoized from one admit pass: a
  # composed branch's invocation is minted by the compose job's own
  # scheduling wake, which may have admitted it already.
  def step_attempt(agent_loop, key)
    invocation_id = node(agent_loop, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  # A round that answers with one compose call, driven all the way
  # through the scheduler so the dispatch and the job are under test too.
  # `wait:` is the CALL's word: absent, the subgraph runs detached — the
  # default a model gets; `true` splices it under the continuation, the
  # shape every attached case below pins.
  def compose_round!(agent_loop, script, params = {}, key: "round1", wait: nil)
    arguments = { script: script, params: params }
    arguments[:wait] = wait unless wait.nil?
    apply_via(step_attempt(agent_loop, key), sse_success("composing", tool_calls: [
      { id: "call_c", name: "compose", arguments: arguments.to_json },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    # Admission is driven by hand below, as every other test here does,
    # so the admit job is deliberately left un-run.
    perform_enqueued_jobs(only: [AgentLoops::ComposeJob, AgentLoops::ScheduleJob]) do
      schedule!(agent_loop)
    end
    agent_loop.reload
  end

  def loop_with_round
    agent_loop = seed(model("round1", "prompt" => "do the work", "instructions" => "you are a kernel"))
    start!(agent_loop)
    agent_loop
  end

  def tool_result(agent_loop, key)
    node(agent_loop, key).content_bodies.find_by(role: "output")&.effective_text
  end

  # A round that also offers `read_file`, so a composed branch inherits a
  # tool it can call and its fan PARKS instead of failing at birth.
  READ_FILE = { "type" => "function",
                "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } }.freeze

  def loop_with_tools
    agent_loop = seed(model("round1", "prompt" => "do the work", "instructions" => "you are a kernel",
      "tools" => [Nexus::Compose::DEFINITION, READ_FILE]))
    start!(agent_loop)
    agent_loop
  end

  def sources_of(agent_loop, key)
    node(agent_loop, key).incoming_edges.includes(:from_node)
      .map { |edge| edge.from_node.node_key }.sort
  end

  # `input_from` on the continuation is the source round, the call's own
  # pairing key, then whatever the composition left unread.
  def read_by(agent_loop, key)
    Array(node(agent_loop, key).input_from_node_keys).map do |source|
      node(agent_loop, source).tool_call_id || source
    end
  end

  # The branch answers with one tool call, so the driver expands it.
  def branch_calls!(agent_loop, key, text)
    apply_via(step_attempt(agent_loop, key), sse_success(text, tool_calls: [
      { id: "call_#{key}", name: "read_file", arguments: '{"path":"a"}' },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    schedule!(agent_loop)
  end

  # The sealed request is the only faithful record of what a step saw.
  def request_texts(agent_loop, key)
    ModelInvocation.find(node(agent_loop, key).selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.filter_map { |e| e.content_fragment.payload.dig("parts", 0, "text") }
  end

  def run!(agent_loop, key, text)
    apply_via(step_attempt(agent_loop, key), sse_success(text))
    AgentLoops::ConvergeTerminalSteps.call
    schedule!(agent_loop)
  end

  def settle_tool!(agent_loop, key, text)
    AgentLoops::Parks::Settle.call(node: node(agent_loop, key), trusted: true,
      content: text, outcome: "completed")
    schedule!(agent_loop)
  end
end
