require "test_helper"

class AgentLoops::Scripts::RunTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  # Longer than the door stores for a provider name, which the builder does not know.
  LONG_PROVIDER = "p" * 65

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "a script reads only declared results in order including business errors and structured false" do
    agent_loop = seed(
      parallel(tool("first", "read_file"), tool("second", "read_file")),
      script("select", "return results;", "results" => %w[second first]),
      model("report")
    )
    start!(agent_loop)
    settle!(loop_node(agent_loop, "first"), "FIRST", structured_content: false)
    settle!(loop_node(agent_loop, "second"), "SECOND", is_error: true, structured_content: { "item" => 2 })
    selected = loop_node(agent_loop, "select")
    run_script!(selected)

    values = AgentLoops::TaskResultProjection.call(selected.reload).fetch("structured_content")
    assert_equal %w[SECOND FIRST], values.map { |value| value.fetch("output") }
    assert_equal [true, false], values.map { |value| value.fetch("is_error") }
    assert_equal [{ "item" => 2 }, false], values.map { |value| value.fetch("structured_content") }
    assert_equal %w[completed completed], values.map { |value| value.fetch("status") }
    assert_equal [{ "type" => "text", "text" => "SECOND" }], values.first.fetch("content")
    assert_nil values.first.fetch("error")
  end

  test "JSON null is a successful value while an empty return is a visible failure" do
    agent_loop = seed(script("null", "return null;"), script("missing", "void 0;", "on_failure" => "absorb"),
      model("report", "results" => %w[null missing]))
    start!(agent_loop)
    run_script!(loop_node(agent_loop, "null"))
    null = loop_node(agent_loop, "null")
    assert_equal "completed", null.status
    assert_equal "null", null.output_body.effective_text
    assert_includes AgentLoops::TaskResultProjection.entry_payloads(null.output_body), { "structured" => nil }

    run_script!(loop_node(agent_loop, "missing"))
    missing = loop_node(agent_loop, "missing")
    assert_equal "failed", missing.status
    assert_equal "script_error", missing.error_key
    assert_includes round_request_entries(loop_node(agent_loop, "report")).to_json, "script_error"
  end

  test "dynamic fan filters and reduces inside a script result boundary" do
    agent_loop = seed(script("workflow", workflow_source),
      model("report", "prompt" => "Report the selected results", "results" => ["workflow"]))
    start!(agent_loop)
    root = loop_node(agent_loop, "workflow")
    run_script!(root)
    listing = children(root).find(&:tool_call?)
    selection = children(root).find(&:script?)
    assert_equal "dispatched", listing.status
    assert_equal "queued", selection.status
    settle!(listing, "RAW LIST SECRET", structured_content: { "files" => %w[a.rb ignored.txt b.rb] })
    run_script!(selection.reload)
    fan = children(selection).select(&:tool_call?).sort_by { |task| task.tool_input.fetch("path") }
    reducer = children(selection).find(&:script?)
    assert_equal %w[a.rb b.rb], fan.map { |task| task.tool_input.fetch("path") }
    assert fan.all? { |task| task.status == "dispatched" }
    assert_equal "queued", reducer.status
    assert_equal "queued", loop_node(agent_loop, "report").status

    settle!(fan.last, "RAW SECOND SECRET", structured_content: { "score" => 2 })
    assert_equal "queued", reducer.reload.status
    settle!(fan.first, "RAW FIRST SECRET", structured_content: { "score" => 1 })
    run_script!(reducer.reload)

    report = loop_node(agent_loop, "report")
    assert_equal "running", report.status
    assert_equal [reducer.node_key], report.result_from_node_keys
    assert_equal({ "scores" => [1, 2] }, AgentLoops::TaskResultProjection.call(reducer.reload)["structured_content"])
    request = round_request_entries(report).to_json
    assert_includes request, "scores"
    assert_not_includes request, "RAW LIST SECRET"
    assert_not_includes request, "RAW FIRST SECRET"
    assert_not_includes request, "RAW SECOND SECRET"
    assert_equal %w[author], AgentLoops::ExpansionOwnership.descendants(root).map(&:authored_by).uniq
  end

  test "an empty selected list returns its value without publishing a fan" do
    agent_loop = seed(script("workflow", workflow_source), model("report", "results" => ["workflow"]))
    start!(agent_loop)
    root = loop_node(agent_loop, "workflow")
    run_script!(root)
    listing = children(root).find(&:tool_call?)
    selection = children(root).find(&:script?)
    settle!(listing, "NO RUBY", structured_content: { "files" => ["notes.txt"] })
    run_script!(selection.reload)

    assert_empty children(selection)
    assert_equal({ "scores" => [] }, AgentLoops::TaskResultProjection.call(selection.reload)["structured_content"])
    assert_equal [selection.node_key], loop_node(agent_loop, "report").result_from_node_keys
    assert_equal "running", loop_node(agent_loop, "report").status
  end

  # The model reference is the door's to judge (a provider name longer than it stores), so this
  # expansion reaches the append door and is refused there, after its steps compiled.
  test "invalid expansion publishes neither partial children nor rewritten consumers" do
    agent_loop = seed(script("invalid", <<~JS, "on_failure" => "absorb"), model("report", "results" => ["invalid"]))
      g.parallel([
        g.tool({name: "read_file", input: {path: "a"}}),
        g.tool({name: "read_file", input: {path: "b"}})
      ]);
      g.model({prompt: "Summarise both files.", model: "#{LONG_PROVIDER}/model"});
    JS
    start!(agent_loop)
    node = loop_node(agent_loop, "invalid")
    before_nodes = agent_loop.agent_loop_nodes.count
    before_edges = agent_loop.agent_loop_edges.count
    run_script!(node)

    assert_equal "failed", node.reload.status
    assert_equal "script_expansion_refused", node.error_key
    assert_equal before_nodes, agent_loop.agent_loop_nodes.count
    assert_equal before_edges, agent_loop.agent_loop_edges.count
    assert_empty children(node)
    report = loop_node(agent_loop, "report")
    assert_equal [node.node_key], report.result_from_node_keys
    assert_includes round_request_entries(report).to_json, "script_expansion_refused"
  end

  test "an expansion refusal locates the author line after regrouping handles" do
    agent_loop = seed(script("invalid", <<~JS, "on_failure" => "absorb"), model("report", "results" => ["invalid"]))
      const source = g.tool({key: "source", name: "read_file", input: {path: "a"}});
      const reader = g.model({key: "reader", prompt: "Read it.", model: "#{LONG_PROVIDER}/model"});
      g.parallel([reader, source]);
      g.script({script: "return null;"});
    JS
    start!(agent_loop)
    node = loop_node(agent_loop, "invalid")
    run_script!(node)

    assert_equal "failed", node.reload.status
    assert_equal "script_expansion_refused", node.error_key
    assert_equal({ "code" => "invalid_model", "step" => "reader", "line" => 2 },
      JSON.parse(node.error_detail))
    assert_empty children(node)
    request = round_request_entries(loop_node(agent_loop, "report")).to_json
    assert_includes request, "invalid_model"
    assert_includes request, "reader"
    assert_includes request, node.error_detail.to_json.delete_prefix('"').delete_suffix('"')
  end

  # The builder refuses what the door would, at evaluation and with the repair: an expansion that
  # ends on a group, and a member that reads a member listed after it. Nothing is published.
  test "a stage the door would refuse is refused at its evaluation with the repair" do
    ends_on_a_group = <<~JS
      g.parallel([g.tool({name: "read_file", input: {path: "a"}}), g.tool({name: "read_file", input: {path: "b"}})]);
    JS
    reads_a_later_member = <<~JS
      const source = g.tool({key: "source", name: "read_file", input: {path: "a"}});
      const reader = g.script({key: "reader", results: [source], script: "return results[0].output;"});
      g.parallel([reader, source]);
      g.script({script: "return null;"});
    JS
    {
      ends_on_a_group => "A g.script stage must end with ONE step such as g.model or g.script, not a " \
        "g.parallel([...]); add a step after the group whose results: name what it reads.",
      reads_a_later_member => %(g.parallel: "reader" reads "source", listed after it; list a step after the steps it reads.),
    }.each do |source, sentence|
      agent_loop = seed(script("invalid", source, "on_failure" => "absorb"), model("report", "results" => ["invalid"]))
      start!(agent_loop)
      node = loop_node(agent_loop, "invalid")
      before_nodes = agent_loop.agent_loop_nodes.count
      run_script!(node)

      assert_equal %w[failed script_error], [node.reload.status, node.error_key], source
      assert_equal "Error: #{sentence}", node.error_detail
      assert_equal before_nodes, agent_loop.agent_loop_nodes.count
      assert_empty children(node)
      assert_includes round_request_entries(loop_node(agent_loop, "report")).to_json,
        sentence.to_json.delete_prefix('"').delete_suffix('"')
    end
  end

  # The door keeps its own rules for every writer, whatever a builder checked first: an attached
  # expansion may not end on a fan's several tips, and none may end on a race's barrier.
  test "the append door refuses a script expansion that does not end on one readable leaf" do
    agent_loop = seed(script("invalid", "return null;", "on_failure" => "absorb"), model("report"))
    start!(agent_loop)
    node = loop_node(agent_loop, "invalid")
    before_nodes = agent_loop.agent_loop_nodes.count
    before_edges = agent_loop.agent_loop_edges.count
    expand = lambda do |group|
      AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
        agent_loop: agent_loop, steps: [AgentLoops::Tasks::Step.from_h(group, "steps[0]")],
        tip: AgentLoops::KernelTool.branch_tip(node), origin: node.authored_by, replaces: node.node_key,
        expansion_parent: node, key_generator: -> { SecureRandom.uuid_v7 }
      ))
    end

    fan = expand.call(parallel(tool("a", "read_file"), tool("b", "read_file")))
    assert_equal [:invalid_steps, %w[fan_needs_follower]], [fan.outcome, fan.errors.map { |error| error["code"] }]
    race = expand.call(parallel(tool("a", "read_file"), tool("b", "read_file"), until: "any"))
    assert_equal :script_requires_single_result, race.outcome, race.errors.inspect
    assert_equal before_nodes, agent_loop.agent_loop_nodes.count
    assert_equal before_edges, agent_loop.agent_loop_edges.count
    assert_empty children(node)
  end

  # A group of one member ends on that member, which the door accepts, and so does the builder.
  test "a stage that ends on a one-member group expands to that member" do
    agent_loop = seed(script("single", 'g.parallel([g.tool({name: "read_file", input: {path: "a"}})]);'),
      model("report", "results" => ["single"]))
    start!(agent_loop)
    node = loop_node(agent_loop, "single")
    run_script!(node)

    assert_equal "completed", node.reload.status
    assert_equal [children(node).sole.node_key], loop_node(agent_loop, "report").result_from_node_keys
  end

  # A STAGE THAT PLACES ITS OWN SCRIPT AGAIN WOULD NEVER END: every expansion places the next copy,
  # and each append is within its own bounds. The copy nested past the cap fails before it is
  # evaluated, the model that composed it reads the sentence, and the chain holds no more stages
  # than the cap allows.
  test "a stage that re-places its own script is stopped past the stage depth cap" do
    source = "g.script({ script: params.src, params: params });"
    cap = AgentLoops::Scripts::Run::MAX_STAGE_DEPTH
    agent_loop = seed(model("round1", "tools" => [Nexus::Compose::DEFINITION]))
    start!(agent_loop)
    run_loop_round!(agent_loop, sse_success("loop", tool_calls: [
      { id: "compose", name: "compose", arguments: { wait: true, script: source, params: { src: source } }.to_json },
    ]))
    call = loop_node(agent_loop, "r1t0")
    AgentLoops::ComposeJob.perform_now(call.id)
    schedule_loop!(agent_loop)
    stage = children(call).sole
    cap.times do
      run_script!(stage.reload)
      assert_equal "completed", stage.reload.status
      stage = children(stage).sole
    end
    run_script!(stage.reload)

    assert_equal %w[failed script_depth_exceeded], [stage.reload.status, stage.error_key]
    assert_equal AgentLoops::Scripts::Run::DEPTH_EXCEEDED, stage.error_detail
    assert_empty children(stage)
    assert_equal cap + 1, agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ScriptTask.sti_name).count
    request = round_request_entries(loop_node(agent_loop, "r1")).to_json
    assert_includes request, "script_depth_exceeded"
    assert_includes request, AgentLoops::Scripts::Run::DEPTH_EXCEEDED.to_json.delete_prefix('"').delete_suffix('"')
  end

  test "a crash after append rolls back the graph and a redelivery publishes once" do
    agent_loop = seed(script("workflow", 'g.tool({name: "read_file", input: {path: "a"}});'),
      model("report", "results" => ["workflow"]))
    start!(agent_loop)
    node = loop_node(agent_loop, "workflow")
    ids = agent_loop.agent_loop_nodes.order(:id).pluck(:id)
    edge_ids = agent_loop.agent_loop_edges.order(:id).pluck(:id)
    original = AgentLoops::Transition.method(:node)
    AgentLoops::Transition.stub(:node, ->(row, **attributes) {
      raise IOError, "worker died before script settlement" if row.id == node.id && attributes[:status] == "completed"

      original.call(row, **attributes)
    }) do
      assert_raises(IOError) { AgentLoops::ScriptJob.perform_now(node.id, node.execution_generation) }
    end
    assert_equal ids, agent_loop.agent_loop_nodes.order(:id).pluck(:id)
    assert_equal edge_ids, agent_loop.agent_loop_edges.order(:id).pluck(:id)
    assert_equal "running", node.reload.status
    assert_nil node.output_body
    assert_equal [node.node_key], loop_node(agent_loop, "report").result_from_node_keys

    run_script!(node)
    committed_ids = agent_loop.agent_loop_nodes.order(:id).pluck(:id)
    assert_equal 1, children(node).length
    AgentLoops::ScriptJob.perform_now(node.id, node.execution_generation)
    assert_equal committed_ids, agent_loop.agent_loop_nodes.order(:id).pluck(:id)
    assert_equal "completed", node.reload.status
  end

  test "model authored script arguments still cross the original approval rules" do
    agent_loop = seed(model("round1", "tools" => [Nexus::Compose::DEFINITION, READ_TOOL]),
      approval_mode: "rules", approval_rules: [
        { "tool" => "compose|read_file", "verdict" => "allow" },
        { "tool" => "read_file", "path" => "path", "match" => "*.secret", "verdict" => "ask" },
      ])
    start!(agent_loop)
    run_loop_round!(agent_loop, sse_success("plan", tool_calls: [
      { id: "compose", name: "compose", arguments: {
        wait: true, script: <<~JS,
          const listing = g.tool({name: "read_file", input: {path: "listing"}});
          g.script({results: [listing], script: 'g.tool({name: "read_file", input: {path: results[0].structured_content.path}});'});
        JS
      }.to_json },
    ]))
    call = loop_node(agent_loop, "r1t0")
    AgentLoops::ComposeJob.perform_now(call.id)
    schedule_loop!(agent_loop)
    stage = children(call).find(&:script?)
    listing = children(call).find(&:tool_call?)
    settle!(listing, "chosen file", structured_content: { "path" => "credentials.secret" })
    run_script!(stage.reload)

    generated = children(stage).sole
    assert_equal "model", generated.authored_by
    assert_equal "needs_approval", generated.status
    assert_equal({ "path" => "credentials.secret" }, generated.tool_input)
    assert_nil generated.claimed_at
    assert_nil generated.approval_origin
  end

  private

    def script(key, source, **fields)
      { "script" => { "key" => key, "script" => source }.merge(fields) }
    end

    def start!(agent_loop)
      assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      )), :accepted?
      schedule_loop!(agent_loop)
    end

    def run_script!(node)
      assert_equal "running", node.status
      AgentLoops::ScriptJob.perform_now(node.id, node.execution_generation)
      schedule_loop!(node.agent_loop)
    end

    def settle!(node, text, **fields)
      result = AgentLoops::Parks::Settle.call(node: node, trusted: true, outcome: "completed", content: text, **fields)
      assert_predicate result, :applied?
      schedule_loop!(node.agent_loop)
    end

    def children(node)
      node.agent_loop.agent_loop_nodes.where(expansion_parent_id: node.id).order(:id).to_a
    end

    def workflow_source
      <<~JS
        const listing = g.tool({name: "read_file", input: {path: "files.json"}});
        g.script({results: [listing], script: `
          const files = results[0].structured_content.files.filter(path => path.endsWith(".rb"));
          if (files.length === 0) return {scores: []};
          const checks = files.map(path => g.tool({name: "read_file", input: {path}}));
          g.parallel(checks);
          g.script({results: checks, script: "return {scores: results.map(result => result.structured_content.score)};"});
        `});
      JS
    end
end
