require "test_helper"

# THE PICTURE OF A RUN: the graph is never written from outside — task-grained authoring keeps it
# sound — but it is READABLE, whole, for debugging, e2e evidence and a UI drawing the workflow.
class AgentAPI::AgentLoopGraphPresenterTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @agent_loop = seed(parallel(model("plan"), model("side"), until: "any", key: "done"), ask("gate"))
  end

  test "every node renders in authoring order, the hidden ones included, in task vocabulary" do
    graph = AgentAPI::AgentLoopGraphPresenter.call(@agent_loop)

    assert_equal %w[plan side done gate], graph.nodes.map(&:key)
    assert_equal %w[model_task model_task join_task await_task], graph.nodes.map(&:kind)
    assert_equal %w[waiting waiting waiting waiting], graph.nodes.map(&:status),
      "the product's word, as the trace spells it"
    assert_equal %w[visible visible hidden hidden], graph.nodes.map(&:visibility),
      "a hidden task is still in the picture; visibility rides so a UI may filter"
    assert_equal [false, false, false, true], graph.nodes.map(&:deliverable)
    assert_equal [false, false, nil, nil], graph.nodes.map(&:spine),
      "a race's members are placed as branches (the compiler's own mark), so neither is the " \
      "conversation's thread; a join and an await carry no mark at all"
    assert_equal @agent_loop.spine_nodes.order(:id).pluck(:node_key), graph.nodes.select(&:spine).map(&:key),
      "the picture's spine is exactly the kernel's `spine_nodes` — the one predicate, not a key's shape"
    assert_equal({ until: "any", losers: "cancel" }, graph.nodes[2].join,
      "a race draws as the barrier the kernel placed, in the words that wrote it")
    assert_nil graph.nodes[0].join
    assert_nil graph.nodes[0].error_key
  end

  # THE SPINE IS THE KERNEL'S MARK, NEVER A KEY'S SHAPE: a compose member's continuations and a
  # summarizer's `kN` are keyed like rounds, and a reader that inferred the thread from `r<N>`
  # counted them as the conversation. The route serves `continuation_source`'s verdict under the one
  # predicate `AgentLoop#spine_nodes` uses — a NULL mark is the spine, `branch` is not, and a node
  # that is no round says nothing.
  test "a round carries the kernel's spine mark and a branch-marked round reads false" do
    agent_loop = seed(model("plan"), detached(model("side", "prompt" => "background")))
    assert_equal "branch", agent_loop.agent_loop_nodes.find_by!(node_key: "side").continuation_source,
      "the fixture is a real branch: the compiler's own mark"

    graph = AgentAPI::AgentLoopGraphPresenter.call(agent_loop)

    assert_equal %w[plan side], graph.nodes.map(&:key)
    assert_equal [true, false], graph.nodes.map(&:spine),
      "an authored round's mark is NULL and that IS the spine; a detached round is a branch"
    assert_equal %w[plan], agent_loop.spine_nodes.pluck(:node_key)
    assert_equal agent_loop.spine_nodes.pluck(:node_key), graph.nodes.select(&:spine).map(&:key),
      "the picture's spine is exactly the kernel's `spine_nodes`"
    rendered = graph.to_h
    assert_equal false, rendered[:nodes][1][:spine], "false rides the wire; only nil is dropped"
  end

  test "edges are keyed, ordered by head then source, and carry no ids" do
    graph = AgentAPI::AgentLoopGraphPresenter.call(@agent_loop)

    assert_equal [%w[plan done], %w[side done], %w[done gate]],
      graph.edges.map { |edge| [edge.from, edge.to] }
    rendered = graph.to_h
    assert_equal %i[nodes edges mermaid], rendered.keys
    assert_equal %i[key kind lifetime wake status visibility deliverable input_from result_from join], rendered[:nodes][2].keys,
      "node attributes are the API's vocabulary and nothing internal"
    assert_equal %i[key kind lifetime wake status visibility deliverable input_from result_from spine], rendered[:nodes][0].keys,
      "a round carries its spine mark and never the column behind it"
    assert_equal %i[from to structural], rendered[:edges].first.keys
    assert_not rendered.to_json.include?(@agent_loop.deliverable_node_id.to_s),
      "no SQL id reaches the wire"
  end

  test "ordered material and result sources stay separate from scheduling dependencies" do
    agent_loop = seed(parallel(tool("a"), tool("b"), model("c", "results" => %w[b a]),
      model("d", "after" => ["a"])), model("report", "results" => %w[a b c d]))
    graph = AgentAPI::AgentLoopGraphPresenter.call(agent_loop)
    nodes = graph.nodes.index_by(&:key)

    assert_equal %w[b a], nodes.fetch("c").result_from
    assert_empty nodes.fetch("c").input_from
    assert_empty nodes.fetch("d").input_from
    assert_empty nodes.fetch("d").result_from
    assert_equal %w[a b c d], nodes.fetch("report").result_from
    assert_empty nodes.fetch("report").input_from
    assert_equal [["a", "c", false], ["b", "c", false], ["a", "d", false],
                  ["a", "report", true], ["b", "report", true], ["c", "report", true], ["d", "report", true]],
      graph.edges.map { |edge| [edge.from, edge.to, edge.structural] }
    assert graph.nodes.none? { |node| node.to_h.key?(:expansion_parent) }
  end

  test "structural placement wins when the same pair is also a reference" do
    agent_loop = seed(tool("a"), tool("b", "after" => ["a"]), model("c", "after" => ["a"]))
    graph = AgentAPI::AgentLoopGraphPresenter.call(agent_loop)

    assert_equal [["a", "b", true], ["a", "c", false], ["b", "c", true]],
      graph.edges.map { |edge| [edge.from, edge.to, edge.structural] }
    assert_empty graph.nodes.last.input_from, "a wait hands the step nothing to read"
    assert_empty graph.nodes.last.result_from
  end

  test "the mermaid text is derived from the same nodes and edges, status as class, deliverable marked" do
    mermaid = AgentAPI::AgentLoopGraphPresenter.call(@agent_loop).mermaid
    lines = mermaid.lines.map(&:chomp)

    assert_equal "flowchart TD", lines.first
    assert_includes lines, %(  n0["plan · model_task · waiting"]:::waiting)
    assert_includes lines, %(  n2["done · join_task (any, cancel) · waiting"]:::waiting)
    assert_includes lines, %(  n3[["gate · await_task · waiting"]]:::waiting),
      "the deliverable draws in the subroutine shape"
    assert_equal ["  n0 --> n2", "  n1 --> n2", "  n2 --> n3"],
      lines.select { |line| line.include?("-->") }
  end

  test "the picture is stable across reads and follows a status change" do
    first = AgentAPI::AgentLoopGraphPresenter.call(@agent_loop)
    second = AgentAPI::AgentLoopGraphPresenter.call(AgentLoop.find(@agent_loop.id))
    assert_equal first, second

    start!(@agent_loop)
    run_step!(@agent_loop, "plan", sse_success("planned"))
    # The loser's running step terminalizes after commit; the converger settles the node.
    AgentLoops::ConvergeTerminalSteps.call

    after = AgentAPI::AgentLoopGraphPresenter.call(@agent_loop.reload)
    assert_equal %w[completed canceled completed dispatched], after.nodes.map(&:status),
      "the race settled on plan, canceled side, and released the gate"
    assert_includes after.mermaid, %(n0["plan · model_task · completed"]:::completed)
    assert_equal first.edges, after.edges, "settlement alone does not rewrite dependencies"
  end

  # Keys are format-checked at compile, but an error key is the kernel's
  # prose and a label is quoted text: the text stays well-formed whatever
  # a node carries.
  test "labels are sanitized and a failed node carries its error key" do
    node_type = Data.define(:id, :node_key, :task_kind, :lifetime, :wake, :status, :transcript_visibility,
      :error_key, :join_mode, :quorum_k, :loser_policy, :continuation_source, :incoming_edges,
      :input_from_node_keys, :result_from_node_keys, :expansion_parent_id)
    plain = { input_from_node_keys: nil, result_from_node_keys: nil, expansion_parent_id: nil }
    edge_type = Data.define(:from_node_id, :structural)
    source = node_type.new(id: 1, node_key: "a-b", task_kind: "model_task", lifetime: "conversation", wake: "auto", status: "queued",
      transcript_visibility: "visible", error_key: nil, join_mode: nil, quorum_k: nil,
      loser_policy: nil, continuation_source: nil, incoming_edges: [], **plain)
    head = node_type.new(id: 2, node_key: "a_b", task_kind: "join_task", lifetime: "conversation", wake: "auto", status: "failed",
      transcript_visibility: "hidden", error_key: %(quorum "x"] --> n0),
      join_mode: "quorum", quorum_k: 2, loser_policy: "cancel_losers", continuation_source: nil,
      incoming_edges: [edge_type.new(from_node_id: source.id, structural: true)], **plain)

    graph = AgentAPI::AgentLoopGraphPresenter.build(nodes: [source, head], deliverable_node_id: 2)

    assert_equal [%w[a-b a_b]], graph.edges.map { |edge| [edge.from, edge.to] },
      "two keys that differ only by separator stay two nodes"
    assert_equal "quorum \"x\"] --> n0", graph.nodes[1].error_key, "the JSON carries it verbatim"
    assert_equal({ until: 2, losers: "cancel" }, graph.nodes[1].join,
      "a quorum reads back as the number that wrote it")
    label = graph.mermaid.lines.find { |line| line.include?("a_b") }.chomp
    assert_equal %(  n1[["a_b · join_task (2, cancel) · failed · quorum _x__ --_ n0"]]:::failed),
      label
    assert_equal ["  n0 --> n1"], graph.mermaid.lines.map(&:chomp).select { |line| line.include?("-->") },
      "an edge only ever comes from an edge"
  end

  test "a read overlapping expansion never draws an edge to a node absent from this picture" do
    agent_loop = seed({ "script" => { "key" => "source", "script" => "g.script({script: 'return 42;'});" } },
      model("reader"))
    start!(agent_loop)
    nodes = agent_loop.agent_loop_nodes.order(:created_at, :id).to_a
    AgentLoops::ScriptJob.perform_now(nodes.first.id, nodes.first.execution_generation)

    graph = AgentAPI::AgentLoopGraphPresenter.build(nodes: nodes, deliverable_node_id: agent_loop.deliverable_node_id)
    assert_equal %w[source reader], graph.nodes.map(&:key)
    assert_equal [%w[source reader]], graph.edges.map { |edge| [edge.from, edge.to] }
    assert_equal ["  n0 --> n1"], graph.mermaid.lines.map(&:chomp).grep(/-->/)
    assert_equal 3, AgentAPI::AgentLoopGraphPresenter.call(agent_loop).nodes.length
  end

  private

    def start!(agent_loop)
      AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      ))
      clear_enqueued_jobs
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      clear_enqueued_jobs
    end

    def run_step!(agent_loop, key, behaviour)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted
        .to_h { |candidate| [candidate.attempt.model_invocation_id, candidate.attempt] }
      clear_enqueued_jobs
      node = agent_loop.agent_loop_nodes.find_by!(node_key: key)
      apply_via(admitted.fetch(node.selected_model_invocation_id), behaviour)
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      clear_enqueued_jobs
    end
end
