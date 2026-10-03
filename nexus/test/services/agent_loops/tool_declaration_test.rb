require "test_helper"

# the tool declaration pipeline: authored tools ride the task, the reserved-facts channel carries
# them to the wire past the lowering table, the capability gates them, and the calls the model makes
# come back as a normalized sealed envelope beside the answer. (The fan expansion that consumes the
# envelope is the round driver.)
class AgentLoops::ToolDeclarationTest < ActiveJob::TestCase
  include InvocationHarness

  READ_TOOL = {
    "type" => "function",
    "function" => {
      "name" => "read_file",
      "description" => "Read one file",
      "parameters" => { "type" => "object",
                        "properties" => { "path" => { "type" => "string" } } },
    },
  }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def compile(steps) = AgentLoops::Tasks::Compile.call(steps, AgentLoops::Tasks::Tip.seed("round"))

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    ))
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def admitted_attempt(agent_loop, key)
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    target = node(agent_loop, key)
    ModelInvocation.find(target.selected_model_invocation_id)
      .attempts.order(:ordinal).last
  end

  def wire(attempt)
    built = build(attempt)
    assert_predicate built, :built?, built.refusal.inspect
    JSON.parse(built.request.payload)
  end

  # The step answers without a call; the next step becomes ready.
  def finish!(agent_loop, attempt)
    apply_via(attempt, sse_success("answered"))
    AgentLoops::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    clear_enqueued_jobs
  end

  test "the grammar: tools accepted on model tasks, refused everywhere else and when empty" do
    accepted = compile([model("m", "tools" => [READ_TOOL])])
    assert_predicate accepted, :valid?
    assert_equal [READ_TOOL], accepted.nodes.sole.fetch("tool_definitions")

    { [model("m", "tools" => [])] => %w[invalid_tools tools: [] reads like disabling something never on],
      [model("m", "tools" => ["junk"])] => %w[invalid_tools non-object tool entries],
      [ask("a", "tools" => [READ_TOOL])] => %w[unknown_step_option tools on an ask is a typo'd intent] }
      .each do |steps, (code, *why)|
      refused = compile(steps)
      assert_equal code, refused.errors.sole.fetch("code"), why.join(" ")
    end
  end

  test "declared tools reach the wire as first-class facts, past the lowering table" do
    agent_loop = seed(model("caller", "tools" => [READ_TOOL]))
    start!(agent_loop)
    attempt = admitted_attempt(agent_loop, "caller")

    built = build(attempt)
    assert_predicate built, :built?
    payload = JSON.parse(built.request.payload)
    tool = payload.fetch("tools").sole
    assert_equal "read_file", tool.dig("function", "name") || tool["name"],
      "the declared NAME survives the storage round-trip - the predecessor's " \
        "K0 defect was a string-keyed tool losing it at the wire"
  end

  test "the calls the model makes come back as one normalized sealed envelope" do
    agent_loop = seed(model("caller", "tools" => [READ_TOOL]))
    start!(agent_loop)
    attempt = admitted_attempt(agent_loop, "caller")
    apply_via(attempt, sse_success("on it", tool_calls: [
      { id: "call_1", name: "read_file", arguments: "{\"path\":\"a.rb\"}" },
      { id: "call_2", name: "read_file", arguments: "{\"path\":\"b.rb\"}" },
    ]))

    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status
    envelope = invocation.content_bodies.find_by!(role: "tool_calls")
      .content_body_entries.sole.content_fragment.payload
    assert_equal "nexus.tool_calls.v1", envelope.fetch("format")
    assert_equal(
      [
        { "id" => "call_1", "name" => "read_file",
          "arguments" => "{\"path\":\"a.rb\"}", "ordinal" => 0 },
        { "id" => "call_2", "name" => "read_file",
          "arguments" => "{\"path\":\"b.rb\"}", "ordinal" => 1 },
      ],
      envelope.fetch("items"),
      "call order is the stored order - the deterministic-recomposition law"
    )

    AgentLoops::ConvergeTerminalSteps.call
    assert_equal "completed", node(agent_loop, "caller").reload.status,
      "declared calls are stored while the node completes"
  end

  # THE SOURCE'S TOOLS, TURNED OFF: a step authored with no tools replays
  # its source's sealed request as history, and on that lane the tool list
  # heads the cached prefix and every replayed thinking block is bound to
  # it — so the step sends the source's `tools` by value under
  # `tool_choice: none` rather than dropping them. The declared set, the
  # delivery gate, stays empty; a step on another lane has no prefix of
  # the source's to keep and sends none.
  test "a tool-less model step continuing a tool-bearing source sends the source's tools with tool_choice none" do
    agent_loop = seed(model("caller", "tools" => [READ_TOOL]), model("judge"),
      model("other", "model" => { "model" => "dev/mock-text-only" }))
    start!(agent_loop)
    caller = admitted_attempt(agent_loop, "caller")
    source_tools = wire(caller).fetch("tools")
    finish!(agent_loop, caller)

    judge = admitted_attempt(agent_loop, "judge")
    assert_nil node(agent_loop, "judge").tool_definitions, "the declared set - the delivery gate - stays empty"
    payload = wire(judge)
    assert_equal source_tools, payload.fetch("tools"), "the source's tools, by value"
    assert_equal "none", payload.fetch("tool_choice"), "and the model cannot call one"
    finish!(agent_loop, judge)

    other = wire(admitted_attempt(agent_loop, "other"))
    assert_not other.key?("tools"), "another lane shares no prefix with the source"
    assert_not other.key?("tool_choice")
  end

  test "a tool-less model step continuing a tool-less source sends neither tools nor tool_choice" do
    agent_loop = seed(model("plain"), model("next"))
    start!(agent_loop)
    finish!(agent_loop, admitted_attempt(agent_loop, "plain"))

    payload = wire(admitted_attempt(agent_loop, "next"))
    assert_not payload.key?("tools")
    assert_not payload.key?("tool_choice")
  end

  test "a round with no calls writes no envelope" do
    agent_loop = seed(model("plain"))
    start!(agent_loop)
    attempt = admitted_attempt(agent_loop, "plain")
    apply_via(attempt, sse_success("answer"))

    assert_nil attempt.model_invocation.reload.content_bodies.find_by(role: "tool_calls")
  end

  test "K0 pinned at the protocol: string-keyed tools are DROPPED, the symbolized lift is load-bearing" do
    string_keyed = [READ_TOOL]
    symbolized = [READ_TOOL.deep_symbolize_keys]

    dropped = SimpleInference::Protocols::AnthropicMessages
      .allocate.send(:normalize_tools, string_keyed)
    kept = SimpleInference::Protocols::AnthropicMessages
      .allocate.send(:normalize_tools, symbolized)

    assert_equal [], dropped,
      "the vendored protocol reads symbol keys only - this IS the K0 trap"
    assert_equal "read_file", kept.sole.fetch(:name),
      "which is why Build's reserved-facts lift deep-symbolizes"
  end
end
