require "json"

# Authored scripts paired with independently drawn route graphs. No evaluator or rehearsal
# builds the expected graph: these small examples can catch drift in either reader.
module ExecutedPlanScenarios
  GREPS = <<~'JS'.freeze
    const files = ["app/models/user.rb", "app/models/account.rb", "app/models/team.rb"];
    const greps = files.map(path => g.tool({ name: "grep", input: { pattern: "def full_name", path } }));
    g.parallel(greps);
  JS
  RACE = <<~'JS'.freeze
    g.parallel(["alpha", "bravo", "charlie"].map(host =>
      g.tool({ name: "bash", input: { command: "sh bin/probe " + host } })), { until: "any" });
    g.model({ prompt: "Name the winning host." });
  JS
  RENDEZVOUS = <<~'JS'.freeze
    const migrate = g.tool({ name: "bash", input: { command: "bin/rails db:migrate" } });
    const seed = g.tool({ name: "bash", input: { command: "bin/rails db:seed" } });
    g.parallel([migrate, seed]);
    const dump = g.tool({ name: "bash", input: { command: "bin/rails db:schema:dump" } });
    const migration = g.model({ prompt: "Review migration.", results: [migrate, dump] });
    const seeding = g.model({ prompt: "Review seed.", results: [seed, dump] });
    g.parallel([migration, seeding]);
    g.model({ prompt: "Merge reviews.", results: [migration, seeding] });
  JS

  module_function

  def all
    { "race" => race, "whole_plan_wrapper" => race(wrapper: true),
      "results_wiring" => rendezvous, "wrapped_rendezvous" => rendezvous(wrapper: true),
      "member_continuation_rounds" => member_rounds, "member_continuation_read" => member_read,
      "normalise_tools" => normalise_tools, "normalise_in_the_fetch" => normalise_in_fetch,
      "stage_decided_edit" => stage_edit, "stage_placed_model" => stage_model,
      "nested_stages" => nested_stages, "failed_stage" => failed_stage,
      "per_source_value_stages" => per_source_values, "value_stages_in_a_race" => race_values }
  end

  def race(wrapper: false)
    parent = "script-1" if wrapper
    nodes = (1..3).map { |i| node("tool-#{i}", "tool", parent: parent, status: i == 2 ? "completed" : "canceled") }
    nodes += [node("parallel-1", "join", parent: parent), node("model-1", "model", parent: parent)]
    edges = grep_waits("parallel-1") + [["parallel-1", "model-1"]]
    if wrapper
      nodes.unshift(node(parent, "script"))
      edges += (1..3).map { |i| [parent, "tool-#{i}"] }
    end
    fixture(wrapper ? wrapped(RACE) : RACE, nodes, edges, objective: "O3")
  end

  def rendezvous(wrapper: false)
    parent = "script-1" if wrapper
    nodes = [*grep_nodes(parent: parent), node("model-1", "model", reads: %w[tool-1 tool-3], parent: parent),
             node("model-2", "model", reads: %w[tool-2 tool-3], parent: parent),
             node("model-3", "model", reads: %w[model-1 model-2], parent: parent)]
    edges = [%w[tool-1 tool-3], %w[tool-2 tool-3], %w[tool-1 model-1], %w[tool-3 model-1],
             %w[tool-2 model-2], %w[tool-3 model-2], %w[model-1 model-3], %w[model-2 model-3]]
    if wrapper
      nodes.unshift(node(parent, "script"))
      edges += [[parent, "tool-1"], [parent, "tool-2"]]
    end
    fixture(wrapper ? wrapped(RENDEZVOUS) : RENDEZVOUS, nodes, edges, objective: "T5")
  end

  def member_rounds
    script = <<~'JS'
      const reviews = ["one", "two", "three"].map(prompt => g.model({ prompt }));
      g.parallel(reviews);
      g.model({ prompt: "Combine reviews.", results: reviews });
    JS
    nodes = (1..3).map { |i| node("model-#{i}", "model") }
    nodes << node("model-4", "model", reads: %w[review-1 review-2 review-3-next])
    edges = (1..3).map { |i| ["model-#{i}", "model-4"] }
    (1..3).each do |i|
      nodes += [node("read-#{i}", "tool", parent: "model-#{i}"), node("review-#{i}", "model", parent: "model-#{i}")]
      edges += [["model-#{i}", "read-#{i}"], ["read-#{i}", "review-#{i}"], ["review-#{i}", "model-4"]]
    end
    nodes += [node("read-again", "tool", parent: "review-3"), node("review-3-next", "model", parent: "review-3")]
    edges += [%w[review-3 read-again], %w[read-again review-3-next], %w[review-3-next model-4]]
    fixture(script, nodes, edges, objective: "O1")
  end

  def member_read
    script = <<~'JS'
      const suite = g.tool({ name: "bash", input: { command: "bin/rails test" } });
      const suiteReport = g.model({ prompt: "Report suite.", results: [suite] });
      const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
      const fix = g.model({ prompt: "Fix lint.", results: [lint] });
      const recheck = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
      const report = g.model({ prompt: "Report recheck.", results: [recheck] });
      g.parallel([[suite, suiteReport], [lint, fix, recheck, report]]);
    JS
    nodes = [node("tool-1", "tool"), node("model-1", "model", reads: ["tool-1"]), node("tool-2", "tool"),
             node("model-2", "model", reads: ["tool-2"]), node("tool-3", "tool"), node("model-3", "model", reads: ["tool-3"]),
             node("edit", "tool", parent: "model-2"), node("continuation", "model", parent: "model-2")]
    fixture(script, nodes, [%w[tool-1 model-1], %w[tool-2 model-2], %w[model-2 tool-3], %w[tool-3 model-3],
                            %w[model-2 edit], %w[edit continuation], %w[continuation tool-3]], objective: "O4")
  end

  def normalise_tools
    script = <<~'JS'
      const pairs = ["a", "b", "c"].map(source => [
        g.tool({ name: "bash", input: { command: "sh bin/fetch " + source } }),
        g.tool({ name: "bash", input: { command: "sh bin/normalise " + source } })
      ]);
      g.parallel(pairs);
      g.tool({ name: "bash", input: { command: "cat normalized.*" } });
    JS
    nodes = (1..7).map { |i| node("tool-#{i}", "tool") }
    fixture(script, nodes, [%w[tool-1 tool-2], %w[tool-3 tool-4], %w[tool-5 tool-6],
                            %w[tool-2 tool-7], %w[tool-4 tool-7], %w[tool-6 tool-7]], objective: "O7", call: "r6t0")
  end

  def normalise_in_fetch
    script = <<~'JS'
      g.parallel(["a", "b", "c"].map(source =>
        g.tool({ name: "bash", input: { command: "sh bin/fetch " + source + " | normalize" } })));
      g.tool({ name: "bash", input: { command: "cat normalized.*" } });
    JS
    fixture(script, (1..4).map { |i| node("tool-#{i}", "tool") }, grep_waits("tool-4"), objective: "O7")
  end

  def stage_edit
    script = GREPS + <<~'JS'
      g.script({ results: greps, script: `
        const edit = g.tool({ name: 'bash', input: { command: 'perl -pi -e s/full_name/display_name/ app/models/team.rb' } });
        g.script({ results: [edit], script: "if (results[0].is_error) throw new Error('edit failed'); return 'edited';" });
      ` });
    JS
    nodes = [*grep_nodes, node("script-1", "script", reads: %w[tool-1 tool-2 tool-3]),
             node("edit", "tool", parent: "script-1"), node("closing", "script", parent: "script-1", reads: ["edit"])]
    fixture(script, nodes, [*grep_waits("script-1"), %w[script-1 edit], %w[edit closing]], objective: "O2")
  end

  def stage_model
    script = GREPS + <<~'JS'
      g.script({ results: greps, script: "g.model({ prompt: 'Rename the matching method: ' + results.map(r => r.output).join('\\n') });" });
    JS
    nodes = [*grep_nodes, node("script-1", "script", reads: %w[tool-1 tool-2 tool-3]),
             node("edit-model", "model", parent: "script-1"), node("edit", "tool", parent: "edit-model"),
             node("continued", "model", parent: "edit-model")]
    fixture(script, nodes, [*grep_waits("script-1"), %w[script-1 edit-model], %w[edit-model edit], %w[edit continued]], objective: "O2")
  end

  def nested_stages
    edit = <<~'JS'
      const edit = g.tool({ name: "edit", input: { path: "app/models/team.rb", old_text: "def full_name", new_text: "def display_name" } });
      const check = g.tool({ name: "grep", input: { path: "app/models/team.rb", pattern: "display_name" } });
      const recheck = g.tool({ name: "grep", input: { path: "app/models/team.rb", pattern: "full_name" } });
      g.script({ results: [edit, check, recheck], script: "return results.map(r => r.output);" });
    JS
    read = "const file = g.tool({ name: 'read', input: { path: 'app/models/team.rb' } }); " \
      "g.script({ results: [file], script: #{JSON.generate(edit)} });"
    script = wrapped(GREPS + "g.script({ results: greps, script: #{JSON.generate(read)} });")
    nodes = [node("script-1", "script"), *grep_nodes(parent: "script-1"),
             node("choose", "script", parent: "script-1", reads: %w[tool-1 tool-2 tool-3]),
             node("read", "tool", parent: "choose"), node("change", "script", parent: "choose", reads: ["read"]),
             node("edit", "tool", parent: "change"), node("check", "tool", parent: "change"), node("recheck", "tool", parent: "change"),
             node("summary", "script", parent: "change", reads: %w[edit check recheck])]
    edges = (1..3).map { |i| ["script-1", "tool-#{i}"] } + grep_waits("choose") +
      [%w[choose read], %w[read change], %w[change edit], %w[edit check], %w[check recheck],
       %w[edit summary], %w[check summary], %w[recheck summary]]
    fixture(script, nodes, edges, objective: "O2")
  end

  def failed_stage
    script = wrapped(GREPS + <<~'JS')
      g.script({ results: greps, script: `
        const output = results.find(r => r.output.startsWith('app/models/team.rb:'));
        if (!output) throw new Error('expected the full path');
        g.tool({ name: 'edit', input: { path: 'app/models/team.rb', old_text: 'def full_name', new_text: 'def display_name' } });
      ` });
    JS
    nodes = [node("script-1", "script"), *grep_nodes(parent: "script-1"),
             node("choose", "script", parent: "script-1", reads: %w[tool-1 tool-2 tool-3], status: "failed")]
    fixture(script, nodes, (1..3).map { |i| ["script-1", "tool-#{i}"] } + grep_waits("choose"), objective: "O2")
  end

  def per_source_values
    script = <<~'JS'
      const pairs = ["a", "b", "c"].map(source => {
        const fetch = g.tool({ name: "bash", input: { command: "sh bin/fetch " + source } });
        return [fetch, g.script({ results: [fetch], script: "return results[0].output;" })];
      });
      g.parallel(pairs);
      g.script({ results: pairs.map(pair => pair[1]), script: "return results.map(r => r.output);" });
    JS
    nodes = [node("script-1", "script")]
    edges = []
    (1..3).each do |i|
      nodes += [node("fetch-#{i}", "tool", parent: "script-1"), node("normalize-#{i}", "script", parent: "script-1", reads: ["fetch-#{i}"])]
      edges += [["script-1", "fetch-#{i}"], ["fetch-#{i}", "normalize-#{i}"], ["normalize-#{i}", "merge"]]
    end
    nodes << node("merge", "script", parent: "script-1", reads: %w[normalize-1 normalize-2 normalize-3])
    fixture(wrapped(script), nodes, edges, objective: "O7")
  end

  def race_values
    script = <<~'JS'
      g.parallel(["alpha", "bravo", "charlie"].map(host => {
        const probe = g.tool({ name: "bash", input: { command: "sh bin/probe " + host } });
        return [probe, g.script({ results: [probe], script: "return results[0].output;" })];
      }), { until: "any" });
      g.model({ prompt: "Name the winning host." });
    JS
    nodes = []
    edges = []
    (1..3).each do |i|
      status = i == 2 ? "completed" : "canceled"
      nodes += [node("tool-#{i}", "tool", status: status), node("script-#{i}", "script", reads: ["tool-#{i}"], status: status)]
      edges += [["tool-#{i}", "script-#{i}"], ["script-#{i}", "parallel-1"]]
    end
    nodes += [node("parallel-1", "join"), node("model-1", "model")]
    fixture(script, nodes, [*edges, %w[parallel-1 model-1]], objective: "O3")
  end

  def node(key, kind, reads: [], parent: nil, status: "completed")
    { "key" => key, "kind" => "#{kind}_task", "status" => status, "expansion_parent" => parent,
      "input_from" => [], "result_from" => reads,
      "join" => (kind == "join" ? { "until" => "any", "losers" => "cancel" } : nil) }.compact
  end

  def fixture(script, nodes, edges, objective:, call: "r2t0")
    key = ->(name) { "#{call}-#{name}" }
    drawn = nodes.map do |entry|
      entry.merge("key" => key.(entry.fetch("key")),
        "expansion_parent" => entry["expansion_parent"] ? key.(entry["expansion_parent"]) : call,
        "result_from" => entry.fetch("result_from").map(&key))
    end
    roots = nodes.map { |entry| entry.fetch("key") } - edges.map(&:last)
    waits = edges.map { |from, to| [key.(from), key.(to)] } + roots.map { |name| [call, key.(name)] }
    { "objective" => objective, "script" => script, "params" => {}, "call" => call,
      "graph" => { "nodes" => [node(call, "tool", parent: call.delete_suffix("t0")), *drawn],
                   "edges" => waits.map { |from, to| { "from" => from, "to" => to } } } }
  end

  def grep_nodes(parent: nil)
    (1..3).map { |i| node("tool-#{i}", "tool", parent: parent) }
  end

  def grep_waits(target) = (1..3).map { |i| ["tool-#{i}", target] }

  def wrapped(script) = "g.script({ script: #{JSON.generate(script)} });"
end
