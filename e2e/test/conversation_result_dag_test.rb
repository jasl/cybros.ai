require_relative "conversation_turn_test"

# MockLLM fixes the authored graph here. These journeys verify deployed Nexus,
# SDK, and rho execution and material flow; they do not measure model authoring.
class ConversationTurnTest
  def test_shared_results_do_not_make_the_first_consumer_wait_for_the_second_source
    boot_rho!
    patch = "patch-#{SecureRandom.hex(8)}"
    checks = "checks-#{SecureRandom.hex(8)}"
    script = <<~JS
      const a = g.tool({name: "bash", input: {command: "printf #{patch}"}, key: "a"});
      const b = g.ask({prompt: "Supply the check result.", key: "b"});
      const c = g.model({prompt: "Review the selected patch.", results: [a], key: "c"});
      const d = g.model({prompt: "Assess the selected patch and checks.", results: [a, b], key: "d"});
      g.parallel([a, b, c, d]);
      g.model({prompt: "Summarize the reviews.", results: [c, d], key: "report"});
    JS
    context = open_result_dag(script)
    held = await("the first consumer finishing while the second source awaits input") do
      tasks = result_dag_tasks(context.fetch, %w[a b c d])
      tasks if tasks.values.none?(nil) && tasks.fetch("b").status == "awaiting_input" &&
        tasks.fetch("c").status == "completed"
    end
    assert_equal "completed", held.fetch("a").status
    assert_equal "waiting", held.fetch("d").status
    assert_includes held.fetch("c").after, held.fetch("a").key
    refute_includes held.fetch("c").after, held.fetch("b").key
    assert_includes held.fetch("d").after, held.fetch("a").key
    assert_includes held.fetch("d").after, held.fetch("b").key
    refute_includes held.fetch("d").after, held.fetch("c").key

    graph = context.graph
    edges = graph.edges.to_h { |edge| [[edge.from, edge.to], edge.structural] }
    { "c" => ["a"], "d" => %w[a b] }.each do |consumer, sources|
      node = graph.node(held.fetch(consumer).key)
      assert_empty node.input_from
      assert_equal sources.map { |source| held.fetch(source).key }, node.result_from
      node.result_from.each { |source| assert_equal false, edges.fetch([source, node.key]) }
    end

    # The call line names the patch too, so the body is read whole: the line after the call.
    delivered_patch = E2E::PrintedEnvelope.of(held.fetch("a").key, patch)
    first_material = result_dag_material(context, held.fetch("c").key)
    assert_includes first_material, delivered_patch
    refute_includes first_material, checks
    context.tasks_context(held.fetch("b").key).resolve(content: checks)
    settled = await_rho_loop(context.agent_loop_public_id, "completed")
    tasks = result_dag_tasks(settled, %w[c d report])
    assert tasks.values.all? { |task| task.status == "completed" }
    report = context.graph.node(tasks.fetch("report").key)
    assert_equal %w[c d].map { |key| held.fetch(key).key }, report.result_from, "the report reads the two reviews it names"
    assert_empty report.input_from, "and nothing the group placed before them"
    second_material = result_dag_material(context, tasks.fetch("d").key)
    assert_includes second_material, delivered_patch
    assert_includes second_material, checks
  end

  def test_a_script_generates_a_runtime_fan_and_exposes_only_its_reduction
    boot_rho!
    nonce = SecureRandom.hex(4)
    noise = "internal-only-#{SecureRandom.hex(8)}"
    records = [
      { "path" => "a-#{nonce}.rb", "score" => 7, "group" => "a" },
      { "path" => "b-#{nonce}.rb", "score" => 11, "group" => "b" },
      { "path" => "notes-#{nonce}.md", "score" => 101, "group" => "a" },
    ]
    FileUtils.cp(File.expand_path("../support/fixtures/result_dag/work.rb", __dir__), @project)
    File.write(File.join(@project, "data.json"), JSON.generate(
      "case" => "dynamic", "records" => records, "noise" => noise
    ))
    reduce = <<~JS
      const items = results.map(result => JSON.parse(result.output))
        .map(item => ({path: item.path, score: item.score}))
        .sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
      return {items, total: items.reduce((sum, item) => sum + item.score, 0)};
    JS
    fan = <<~JS
      const paths = JSON.parse(results[0].output).files.filter(path => path.endsWith(".rb"));
      const reads = paths.map(path => g.tool({name: "bash", input: {command: "ruby work.rb inspect " + path}}));
      g.parallel(reads);
      g.script({results: reads, script: #{JSON.generate(reduce)}});
    JS
    workflow = <<~JS
      const listing = g.tool({name: "bash", input: {command: "ruby work.rb list"}});
      g.script({results: [listing], script: #{JSON.generate(fan)}});
    JS
    context = open_result_dag("g.script({key: 'workflow', script: #{JSON.generate(workflow)}});")
    settled = await_rho_loop(context.agent_loop_public_id, "completed")
    scripts = settled.tasks.select { |task| task.kind == "script_task" }
    assert_equal 3, scripts.length
    assert scripts.all? { |task| task.status == "completed" }
    reduced = scripts.filter_map do |task|
      detail = context.task(task.key)
      detail if detail.structured_content&.key?("items")
    end
    assert_equal 1, reduced.length
    expected = { "items" => records.first(2).map { |record| record.slice("path", "score") }, "total" => 18 }
    assert_equal expected, reduced.first.structured_content
    assert_equal expected, JSON.parse(reduced.first.output)

    commands = settled.tasks.select { |task| task.tool_name == "bash" }.map { |task| context.task(task.key) }
    assert_equal ["ruby work.rb list", *records.first(2).map { |record| "ruby work.rb inspect #{record.fetch("path")}" }].sort,
      commands.map { |detail| detail.tool_input.fetch("command") }.sort
    assert commands.all? { |detail| detail.task.status == "completed" }
    inspectors = commands.select { |detail| detail.tool_input.fetch("command").start_with?("ruby work.rb inspect ") }
    refute_includes inspectors.first.task.after, inspectors.last.task.key
    refute_includes inspectors.last.task.after, inspectors.first.task.key

    graph = context.graph
    workflow_task = scripts.find { |task| task.key.end_with?("-workflow") }
    reduction = graph.node(reduced.first.task.key)
    fan_task = scripts.find { |task| task.key != workflow_task.key && task.key != reduction.key }
    listing = commands.find { |detail| detail.tool_input.fetch("command") == "ruby work.rb list" }
    inspector_keys = inspectors.sort_by { |detail| detail.tool_input.fetch("command") }.map { |detail| detail.task.key }
    compose = settled.tasks.find { |task| task.tool_name == "compose" }
    assert_equal compose.key, graph.node(workflow_task.key).expansion_parent
    [listing.task.key, fan_task.key].each do |key|
      assert_equal workflow_task.key, graph.node(key).expansion_parent
    end
    [*inspector_keys, reduction.key].each do |key|
      assert_equal fan_task.key, graph.node(key).expansion_parent
    end
    assert_equal [listing.task.key], graph.node(fan_task.key).result_from
    assert_equal inspector_keys, reduction.result_from
    assert_empty reduction.input_from
    assert_equal [reduction.key], graph.deliverable.result_from
    edges = graph.edges.to_h { |edge| [[edge.from, edge.to], edge.structural] }
    inspector_keys.each { |key| assert_equal true, edges.fetch([key, reduction.key]) }

    material = result_dag_material(context, settled.deliverable_task_key)
    assert_includes material, "task=\"#{reduced.first.task.key}\""
    assert_includes material, reduced.first.output
    refute_includes material, noise, "internal listing and inspection outputs must stay inside the script"
    commands.each { |detail| refute_includes material, "task=\"#{detail.task.key}\"" }
  end

  private

    def open_result_dag(script)
      arguments = CGI.escape(JSON.generate("script" => script, "wait" => true))
      _conversation, loop_id = rho_open("!mock tool_call=compose tool_args=#{arguments} -- report the workflow")
      rho_loops.agent_loop(loop_id)
    end

    def result_dag_tasks(loop_row, keys)
      keys.to_h { |key| [key, loop_row.tasks.find { |task| task.key.end_with?("-#{key}") }] }
    end

    def result_dag_material(context, key)
      context.tasks_context(key).request.entries.select { |entry| entry["role"] == "user" }
        .flat_map { |entry| entry.fetch("parts").filter_map { |part| part["text"] } }
        .join("\n")
    end
end
