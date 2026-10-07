require_relative "conversation_turn_test"

# MockLLM fixes the authored graph here. These journeys verify deployed Nexus,
# SDK, and rho execution and material flow; they do not measure model authoring.
class ConversationTurnTest
  def test_shared_results_do_not_make_the_first_consumer_wait_for_the_second_source
    boot_rho!
    patch = "patch-#{SecureRandom.hex(8)}"
    checks = "checks-#{SecureRandom.hex(8)}"
    steps = [
      { "parallel" => [
        { "tool" => { "name" => "bash", "route" => rho_runner_route, "input" => { "command" => "printf #{patch}" }, "key" => "a" } },
        { "ask" => { "prompt" => "Supply the check result.", "key" => "b" } },
        { "model" => { "prompt" => "Review the selected patch.", "results" => ["a"], "key" => "c" } },
        { "model" => { "prompt" => "Assess the selected patch and checks.", "results" => %w[a b], "key" => "d" } },
      ] },
      { "model" => { "prompt" => "Summarize the reviews.", "results" => %w[c d], "key" => "report" } },
    ]
    context = open_result_dag("text(JSON.stringify(await nexus.steps(#{JSON.generate(steps)})));")
    selectors = { "a" => "printf #{patch}", "b" => "Supply the check result.", "c" => "Review the selected patch.",
                  "d" => "Assess the selected patch and checks.", "report" => "Summarize the reviews." }
    held = await("the first consumer finishing while the second source awaits input") do
      tasks = result_dag_tasks(context, selectors.slice(*%w[a b c d]))
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
    settled = await_rho_loop(context.run_public_id, "completed")
    tasks = result_dag_tasks(context, selectors.slice(*%w[c d report]))
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
    program = <<~JS
      const listing = await tools.bash({command: "ruby work.rb list"});
      if (listing.is_error) throw new Error("listing failed");
      const paths = JSON.parse(listing.output).files.filter(path => path.endsWith(".rb"));
      const results = await Promise.all(paths.map(path => tools.bash({command: "ruby work.rb inspect " + path})));
      const items = results.map(result => JSON.parse(result.output))
        .map(item => ({path: item.path, score: item.score}))
        .sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
      const reduced = {items, total: items.reduce((sum, item) => sum + item.score, 0)};
      text(JSON.stringify(reduced));
      return reduced;
    JS
    context = open_result_dag(program)
    settled = await_rho_loop(context.run_public_id, "completed")
    parent = settled.tasks.find { |task| task.tool_name == "code" }
    refute_nil parent
    assert_equal "completed", parent.status
    reduced = context.task(parent.key)
    expected = { "items" => records.first(2).map { |record| record.slice("path", "score") }, "total" => 18 }
    assert_equal expected, reduced.structured_content
    assert_equal expected, JSON.parse(reduced.output)

    commands = settled.tasks.select { |task| task.tool_name == "bash" }.map { |task| context.task(task.key) }
    assert_equal ["ruby work.rb list", *records.first(2).map { |record| "ruby work.rb inspect #{record.fetch("path")}" }].sort,
      commands.map { |detail| detail.tool_input.fetch("command") }.sort
    assert commands.all? { |detail| detail.task.status == "completed" }
    inspectors = commands.select { |detail| detail.tool_input.fetch("command").start_with?("ruby work.rb inspect ") }
    refute_includes inspectors.first.task.after, inspectors.last.task.key
    refute_includes inspectors.last.task.after, inspectors.first.task.key
    graph = context.graph
    commands.each { |detail| assert_equal parent.key, graph.node(detail.task.key).expansion_parent }
    assert_includes graph.deliverable.input_from, parent.key
    assert_empty graph.deliverable.result_from

    entries = context.tasks_context(settled.deliverable_task_key).request.entries
    results = entries.select { |entry| entry["type"] == "tool_result_item" }.map { |entry| entry.fetch("payload") }
    selected = results.select { |result| result["name"] == "code" }
    assert_equal [reduced.output], selected.map { |result| result.fetch("output") },
      "the ordinary tool result carries only the code task's selected reduction"
    refute results.any? { |result| result["name"] == "bash" }, "subordinate calls stay inside the code task"
    refute_includes JSON.generate(entries), noise, "internal listing and inspection outputs stay inside the code task"
  end

  private

    def open_result_dag(script)
      arguments = CGI.escape(JSON.generate("code" => script))
      _conversation, loop_id = rho_open("!mock tool_call=code tool_args=#{arguments} -- report the workflow")
      rho_loops.run(loop_id)
    end


    def result_dag_material(context, key)
      context.tasks_context(key).request.entries.select { |entry| entry["role"] == "user" }
        .flat_map { |entry| entry.fetch("parts").filter_map { |part| part["text"] } }
        .join("\n")
    end
end
