require "test_helper"

# A RACE NAMED AS A RESULT. A placed race is one step a later step may name in `results:`: the
# reader waits on the barrier alone — so nothing it names keeps a loser alive — and reads what the
# race selected when it settled (`TaskResultProjection.referenced`). A stage's slot for it is
# envelope-shaped: the first selected envelope's fields at the top level, or the race's own
# failure, and `selected` beside them.
class AgentLoops::RaceResultsTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  # A reducer that names every probe waits for the slowest one, spares every loser and reads the
  # first envelope in list order. Naming the race, it runs the moment the race settles, the loser
  # is canceled, and `results[0].status` and `.output` read the winner.
  test "a stage reading a race runs when the race settles, reads the winner, and the loser is canceled" do
    agent_loop = seed(
      parallel(tool("fast", "read_file"), tool("slow", "read_file"), until: "any", key: "race"),
      script("pick", "const won = results[0]; " \
                     "return {status: won.status, output: won.output, selected: won.selected.map(r => r.output)};",
        "results" => ["race"]),
      model("report")
    )
    start!(agent_loop)
    pick = loop_node(agent_loop, "pick")
    assert_equal ["race"], pick.result_from_node_keys
    assert_equal ["race"], pick.sources.map(&:node_key), "the stage waits on the barrier alone"

    settle!(loop_node(agent_loop, "fast"), "fast: 200 OK (2s)")
    assert_equal "completed", loop_node(agent_loop, "race").status
    assert_equal %w[canceled join_loser_canceled], loop_node(agent_loop, "slow").values_at(:status, :error_key),
      "nothing but the settled barrier consumed the loser"
    run_script!(pick.reload)

    assert_equal({ "status" => "completed", "output" => "fast: 200 OK (2s)", "selected" => ["fast: 200 OK (2s)"] },
      structured(pick))
  end

  test "a starved race reads as its own failure at the top of the slot and in selected" do
    agent_loop = seed(
      parallel(tool("a", "read_file"), tool("b", "read_file"), until: "any", key: "race", on_failure: "absorb"),
      script("pick", "return results[0];", "results" => ["race"]),
      model("report")
    )
    start!(agent_loop)
    fail!(loop_node(agent_loop, "a"))
    fail!(loop_node(agent_loop, "b"))
    assert_equal %w[failed join_starved], loop_node(agent_loop, "race").values_at(:status, :error_key)
    run_script!(loop_node(agent_loop, "pick"))

    slot = structured(loop_node(agent_loop, "pick"))
    failure = { "status" => "failed", "is_error" => false, "output" => nil, "content" => nil,
                "structured_content" => nil, "error" => { "key" => "join_starved", "detail" => nil } }
    assert_equal failure.merge("selected" => [failure]), slot
  end

  test "a quorum's slot holds every selected envelope, first finisher first" do
    agent_loop = seed(
      parallel(tool("a", "read_file"), tool("b", "read_file"), tool("c", "read_file"), until: 2, key: "race"),
      script("pick", "return {first: results[0].output, all: results[0].selected.map(r => r.output)};",
        "results" => ["race"]),
      model("report")
    )
    start!(agent_loop)
    settle!(loop_node(agent_loop, "c"), "C")
    travel 1.second
    settle!(loop_node(agent_loop, "a"), "A")
    assert_equal "completed", loop_node(agent_loop, "race").status
    run_script!(loop_node(agent_loop, "pick"))

    assert_equal({ "first" => "C", "all" => %w[C A] }, structured(loop_node(agent_loop, "pick")))
  end

  # A FAILED RACE HANDS EVERY READER what it captured before failing, then its own failure — the
  # one selection the wait tool, detached delivery and a model step read too. The top of the slot
  # is the failure, so a reducer checking `results[0].status` never reads a partial winner as the
  # race's answer.
  test "a failed quorum's slot is its failure, with the partial winner selected before it" do
    agent_loop = seed(
      parallel(tool("a", "read_file"), tool("b", "read_file"), tool("c", "read_file"),
        until: 2, key: "race", on_failure: "absorb"),
      script("pick", "return results[0];", "results" => ["race"]),
      model("report")
    )
    start!(agent_loop)
    settle!(loop_node(agent_loop, "a"), "A")
    travel 1.second
    fail!(loop_node(agent_loop, "b"))
    fail!(loop_node(agent_loop, "c"))
    assert_equal %w[failed quorum_unreachable], loop_node(agent_loop, "race").values_at(:status, :error_key)
    run_script!(loop_node(agent_loop, "pick"))

    slot = structured(loop_node(agent_loop, "pick"))
    assert_equal ["failed", "quorum_unreachable"], [slot["status"], slot.dig("error", "key")]
    assert_equal [["completed", "A"], ["failed", nil]], slot["selected"].map { |envelope| envelope.values_at("status", "output") }
  end

  test "a nested race is followed to its winners" do
    agent_loop = seed(
      parallel(parallel(tool("a", "read_file"), tool("b", "read_file"), until: "any", key: "inner"),
        tool("c", "read_file"), until: "any", key: "outer"),
      script("pick", "return results[0].selected.map(r => r.output);", "results" => ["outer"]),
      model("report")
    )
    start!(agent_loop)
    settle!(loop_node(agent_loop, "b"), "B")
    assert_equal %w[completed completed], %w[inner outer].map { |key| loop_node(agent_loop, key).status }
    run_script!(loop_node(agent_loop, "pick"))

    assert_equal ["B"], structured(loop_node(agent_loop, "pick"))
  end

  # A model step naming a race reads the winners as result material, once each — the explicit read
  # and the race-filtered ordinary one are the same row — and the selection is the one captured
  # when the race settled: a run-out loser that answers later is never read.
  test "a model naming a race reads the winner once and never a loser that answered later" do
    agent_loop = seed(
      parallel(tool("fast", "read_file", "input" => { "path" => "fast" }),
        tool("slow", "read_file", "input" => { "path" => "slow" }), until: "any", losers: "run_out", key: "race"),
      model("reader", "results" => ["race"]),
      model("final")
    )
    start!(agent_loop)
    settle!(loop_node(agent_loop, "fast"), "FAST ANSWER")
    reader = loop_node(agent_loop, "reader")
    assert_equal "running", reader.status
    sealed = round_request_entries(reader).to_json
    assert_equal 1, sealed.scan("FAST ANSWER").length

    settle!(loop_node(agent_loop, "slow"), "SLOW ANSWER")
    texts = AgentLoops::InputComposition.call(node: reader.reload, input: reader.input_value)
      .elements.map { |element| element.parts.first.text }
    assert_includes texts, "<task_result task=\"fast\" status=\"completed\">\n" \
      "<call>read_file {\"path\":\"fast\"}</call>\nFAST ANSWER\n</task_result>"
    assert_equal 1, texts.join.scan("FAST ANSWER").length
    refute_includes texts.join, "SLOW ANSWER"
  end

  # A RETRIED LOSER re-runs the same row, so the race's answer stays the selection it captured when
  # it settled: the loser's late answer after a person's retry is never read through the race.
  test "retrying a failed race loser does not turn its late answer into a winner" do
    agent_loop = seed(
      parallel(tool("fast", "read_file", "input" => { "path" => "fast" }),
        tool("slow", "read_file", "input" => { "path" => "slow" }), until: "any", losers: "run_out", key: "race"),
      model("reader", "results" => ["race"]),
      model("final")
    )
    start!(agent_loop)
    settle!(loop_node(agent_loop, "fast"), "FAST ANSWER")
    fail!(loop_node(agent_loop, "slow"))
    retried = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "slow", acting_user: @human
    ))
    assert_predicate retried, :accepted?, retried.outcome.inspect
    schedule_loop!(agent_loop)
    settle!(loop_node(agent_loop, "slow"), "RECOVERED LATE ANSWER")
    assert_equal "completed", loop_node(agent_loop, "slow").status

    reader = loop_node(agent_loop, "reader")
    assert_equal %w[fast], AgentLoops::TaskResultProjection.tips(agent_loop, [loop_node(agent_loop, "race")]).map(&:node_key)
    texts = AgentLoops::InputComposition.call(node: reader, input: reader.input_value)
      .elements.map { |element| element.parts.first.text }.join
    assert_includes texts, "FAST ANSWER"
    refute_includes texts, "RECOVERED LATE ANSWER"
  end

  # THE BATCH HISTORY READER reads a round's `results` as its request did: a history re-rendered
  # for a later round or handed to the summariser (`InputComposition.material_by_round`, the
  # compaction's delivered material) reads a race named as a result as what it selected — the
  # winner, once — never as the join row.
  test "the history reader renders a race named as a result as its winner, never the join row" do
    agent_loop = seed(
      parallel(tool("fast", "read_file", "input" => { "path" => "fast" }),
        tool("slow", "read_file", "input" => { "path" => "slow" }), until: "any", key: "race"),
      model("reader", "results" => ["race"]),
      model("final")
    )
    start!(agent_loop)
    settle!(loop_node(agent_loop, "fast"), "FAST ANSWER")
    run_loop_round!(agent_loop, sse_success("fast answered first"))
    reader = loop_node(agent_loop, "reader")
    assert_equal "completed", reader.status

    delivered = AgentLoops::InputComposition.delivered_sources_by_round([reader]).fetch(reader.id)
    assert_equal ["fast"], delivered.map { |tip, _boundary| tip.node_key }, "the winner once; the join row is no material"
    texts = AgentLoops::InputComposition.material_by_round([reader]).fetch(reader.id).map { |message| message.parts.first.text }
    assert_equal ["<task_result task=\"fast\" status=\"completed\">\n<call>read_file {\"path\":\"fast\"}</call>\n" \
                  "FAST ANSWER\n</task_result>"], texts
  end

  # A model step naming a FAILED race reads the race's one selection too — the partial winner, then
  # the race's failure — the reading a stage, the wait tool and detached delivery share.
  test "a model naming a failed quorum reads its partial winner, then its failure" do
    agent_loop = seed(
      parallel(tool("a", "read_file", "input" => { "path" => "a" }), tool("b", "read_file", "input" => { "path" => "b" }),
        tool("c", "read_file", "input" => { "path" => "c" }), until: 2, key: "race", on_failure: "absorb"),
      model("reader", "results" => ["race"]),
      model("final")
    )
    start!(agent_loop)
    settle!(loop_node(agent_loop, "a"), "A ANSWER")
    travel 1.second
    fail!(loop_node(agent_loop, "b"))
    fail!(loop_node(agent_loop, "c"))
    assert_equal %w[failed quorum_unreachable], loop_node(agent_loop, "race").values_at(:status, :error_key)

    reader = loop_node(agent_loop, "reader")
    texts = AgentLoops::InputComposition.call(node: reader, input: reader.input_value)
      .elements.map { |element| element.parts.first.text }
    winner = texts.index("<task_result task=\"a\" status=\"completed\">\n<call>read_file {\"path\":\"a\"}</call>\n" \
                         "A ANSWER\n</task_result>")
    failure = texts.index { |text| text.start_with?("<task_result task=\"race\" status=\"failed\">\nquorum_unreachable") }
    refute_nil winner, texts.inspect
    refute_nil failure, texts.inspect
    assert_operator winner, :<, failure, "the partial winner first, then the failure"
    assert_equal 1, texts.join.scan("A ANSWER").length, "the winner is rendered once"
  end

  # THE KERNEL'S OWN REWRITE keeps a race named as a result: a stage that expands re-points its
  # reader's slot to the expansion's tail, and the race beside it in the same `results` still reads.
  test "a stage expanding beside a race re-points its reader and keeps the race" do
    agent_loop = seed(
      parallel(tool("a", "read_file"), tool("b", "read_file"), until: "any", key: "race"),
      script("expand", 'g.tool({name: "read_file", input: {path: "more"}});'),
      model("reader", "results" => %w[race expand]),
      model("final")
    )
    start!(agent_loop)
    settle!(loop_node(agent_loop, "a"), "A")
    expand = loop_node(agent_loop, "expand")
    run_script!(expand)

    assert_equal "completed", expand.reload.status, expand.error_key.inspect
    tail = agent_loop.agent_loop_nodes.find_by!(expansion_parent_id: expand.id)
    assert_equal ["race", tail.node_key], loop_node(agent_loop, "reader").result_from_node_keys
  end

  # A race that selected nothing — a person's resolving cancel stops it before it settles — is read
  # as its own row, never as an empty slot.
  test "a race that selected nothing is read as itself" do
    agent_loop = seed(
      parallel(tool("a", "read_file"), tool("b", "read_file"), until: "any", key: "race"),
      model("report")
    )
    race = loop_node(agent_loop, "race")
    race.update_columns(status: "canceled", failure_resolution: "canceled", completed_at: Time.current)

    assert_equal [race], AgentLoops::TaskResultProjection.referenced(race)
    slot = AgentLoops::TaskResultProjection.slot(race)
    assert_equal "canceled", slot["status"]
    assert_equal [slot.except("selected")], slot["selected"]
    leaf = loop_node(agent_loop, "a")
    assert_equal [leaf], AgentLoops::TaskResultProjection.referenced(leaf)
    refute AgentLoops::TaskResultProjection.slot(leaf).key?("selected"), "a leaf's slot is its envelope alone"
  end

  # A MODEL NAMING A RACE OF STAGE EXITS reads what the race selected: the stage it selected, once —
  # never a loser's, canceled, queued or answering later, and never the winning arm's own tool.
  test "a model naming a race of stage exits is delivered the winner's stage and never a canceled loser" do
    agent_loop = seed(wrapped_race, model("report", "results" => ["race"]))
    start!(agent_loop)
    settle!(loop_node(agent_loop, "fast"), "FAST")
    run_script!(loop_node(agent_loop, "wrap-fast"))

    assert_equal %w[canceled join_loser_canceled], loop_node(agent_loop, "wrap-slow").values_at(:status, :error_key)
    report = loop_node(agent_loop, "report")
    assert_equal "running", report.status
    texts = user_texts(round_request_entries(report))
    assert_equal [envelope("wrap-fast", '{"host":"fast","output":"FAST"}'), "p"], texts
    refute_includes texts.join, 'task="wrap-slow"'
    refute_includes texts.join, "join_loser_canceled"
  end

  # A MIXED RACE: a tool winner is the race's selection like any other exit, and renders once.
  test "a mixed race's tool winner is delivered once and the losing arm's stage never" do
    agent_loop = seed(mixed_race, model("report", "results" => ["race"]))
    start!(agent_loop)
    settle!(loop_node(agent_loop, "a"), "A")

    assert_equal "canceled", loop_node(agent_loop, "sb").status
    report = loop_node(agent_loop, "report")
    assert_equal "running", report.status
    assert_equal [envelope("a", '<call>read_file {"path":"a"}</call>', "A"), "p"],
      user_texts(round_request_entries(report))
  end

  test "a mixed race's stage winner is delivered without its arm's tool, and the losing tool never" do
    agent_loop = seed(mixed_race, model("report", "results" => ["race"]))
    start!(agent_loop)
    settle!(loop_node(agent_loop, "b"), "B")
    run_script!(loop_node(agent_loop, "sb"))

    assert_equal "canceled", loop_node(agent_loop, "a").status
    assert_equal [envelope("sb", '"B"'), "p"],
      user_texts(round_request_entries(loop_node(agent_loop, "report"))), "the selection alone"
  end

  # A MODEL WINNER BEHIND A SPINE: the reader continues the spine and reads the race it names —
  # the winning branch once, through the result path, carrying its brief as every model result a
  # step reads does.
  test "a model winner behind a spine renders once through the result path" do
    agent_loop = seed(model("r0"),
      parallel([model("m", "prompt" => "approach M")],
        [tool("t", "read_file"), script("s", "return results[0].output;", "results" => ["t"])],
        until: "any", key: "race"),
      model("report", "results" => ["race"]))
    start!(agent_loop)
    run_loop_round!(agent_loop, sse_success("R0 ANSWER"))
    run_loop_round!(agent_loop, sse_success("M ANSWER"))

    assert_equal "canceled", loop_node(agent_loop, "s").status
    report = loop_node(agent_loop, "report")
    assert_equal "running", report.status
    entries = round_request_entries(report)
    tail = entries.drop(entries.rindex { |entry| entry["role"] == "assistant" } + 1)
    assert_equal [envelope("m", "<prompt>approach M</prompt>", "Mock: M ANSWER"), "p"], user_texts(tail)
  end

  test "a run-out loser's stage that completes later is never read" do
    agent_loop = seed(wrapped_race(losers: "run_out"), model("report", "results" => ["race"]))
    start!(agent_loop)
    settle!(loop_node(agent_loop, "fast"), "FAST")
    run_script!(loop_node(agent_loop, "wrap-fast"))
    report = loop_node(agent_loop, "report")
    assert_equal "running", report.status
    refute_includes user_texts(round_request_entries(report)).join, 'task="wrap-slow"',
      "the loser's stage is still queued when the race settles"

    settle!(loop_node(agent_loop, "slow"), "SLOW")
    run_script!(loop_node(agent_loop, "wrap-slow"))
    assert_equal "completed", loop_node(agent_loop, "wrap-slow").status
    texts = AgentLoops::InputComposition.call(node: report.reload, input: report.input_value)
      .elements.map { |element| element.parts.first.text }
    refute_includes texts.join, 'task="wrap-slow"', "a stage that answered after the race settled is never read"
  end

  # A FAILED RACE OF STAGE EXITS hands the reader naming it what it captured before failing, then
  # its own failure; the arms' tools and stages are read through the race, never as themselves.
  test "a failed quorum of stage exits hands its reader the partial winner, then the race's failure" do
    arms = %w[a b c].map do |key|
      [tool(key, "read_file", "input" => { "path" => key }), script("s#{key}", "return results[0].output;", "results" => [key])]
    end
    agent_loop = seed(parallel(*arms, until: 2, key: "race", on_failure: "absorb"), model("report", "results" => ["race"]))
    start!(agent_loop)
    settle!(loop_node(agent_loop, "a"), "A")
    run_script!(loop_node(agent_loop, "sa"))
    travel 1.second
    fail!(loop_node(agent_loop, "b"))
    fail!(loop_node(agent_loop, "c"))
    assert_equal %w[failed quorum_unreachable], loop_node(agent_loop, "race").values_at(:status, :error_key)

    report = loop_node(agent_loop, "report")
    texts = AgentLoops::InputComposition.call(node: report, input: report.input_value)
      .elements.map { |element| element.parts.first.text }
    assert_equal ['<task_result task="sa" status="completed">', '<task_result task="race" status="failed">', "p"],
      texts.map { |text| text.lines.first.chomp }
    assert_equal envelope("race", "quorum_unreachable", status: "failed"), texts[-2]
  end

  # THE SAME RULE AT EVERY DOOR: a race a stage's body places is lowered by the one compiler, so
  # the model inside the expansion reads the race it names, and nothing of it by position.
  test "a race of stage exits inside a stage's subgraph: the follower inside reads the race it names" do
    body = <<~JS
      const arms = ["fast", "slow"].map((host) => {
        const probe = g.tool({ name: "read_file", input: { path: host } });
        return [probe, g.script({ script: "return results[0].output;", results: [probe] })];
      });
      const race = g.parallel(arms, { until: "any" });
      g.model({ prompt: "report the winner", results: [race] });
    JS
    agent_loop = seed(script("stage", body, "model_defaults" => { "model" => MOCK_MODEL, "tools" => [READ_TOOL] }),
      model("report"))
    start!(agent_loop)
    stage = loop_node(agent_loop, "stage")
    run_script!(stage)

    assert_equal "completed", stage.reload.status, stage.error_key.inspect
    generated = agent_loop.agent_loop_nodes.where(expansion_parent_id: stage.id).to_a
    join = generated.find(&:race?)
    follower = generated.find(&:round?)
    assert_equal [join.node_key], follower.result_from_node_keys
    assert_nil follower.input_from_node_keys
  end

  # An authored envelope ending on the race carries nothing into the next append: a later append
  # names the race by its key and reads it as a result — never as material, which the door would
  # refuse.
  test "an authored envelope ending on a race of stage exits is grown by a model that names the race" do
    agent_loop = seed(wrapped_race)
    start!(agent_loop)
    grow!(agent_loop, model("report", "results" => ["race"]))

    assert_equal ["race"], loop_node(agent_loop, "report").result_from_node_keys
    assert_nil loop_node(agent_loop, "report").input_from_node_keys
  end

  # THE BATCH HISTORY READER reads a named race as the request did: the winner's stage as a result,
  # never the winning arm's tool — what the summariser and a later history render.
  test "the history reader renders a named race as its selection alone" do
    agent_loop = seed(wrapped_race, model("report", "results" => ["race"]), model("final"))
    start!(agent_loop)
    settle!(loop_node(agent_loop, "fast"), "FAST")
    run_script!(loop_node(agent_loop, "wrap-fast"))
    run_loop_round!(agent_loop, sse_success("fast won"))
    report = loop_node(agent_loop, "report")
    assert_equal "completed", report.status

    delivered = AgentLoops::InputComposition.delivered_sources_by_round([report]).fetch(report.id)
    assert_equal [["wrap-fast", true]], delivered.map { |tip, boundary| [tip.node_key, boundary] }
  end

  private

    # Two probes, each wrapped by a stage that ends its arm — `[probe, verdict]` per host, raced:
    # the shape the race cells' floor models write.
    def wrapped_race(**over)
      arms = %w[fast slow].map do |host|
        [tool(host, "read_file", "input" => { "path" => host }),
         script("wrap-#{host}", "return {host: params.host, output: results[0].output};",
           "params" => { "host" => host }, "results" => [host])]
      end
      parallel(*arms, until: "any", key: "race", **over)
    end

    def mixed_race
      parallel(tool("a", "read_file", "input" => { "path" => "a" }),
        [tool("b", "read_file", "input" => { "path" => "b" }), script("sb", "return results[0].output;", "results" => ["b"])],
        until: "any", key: "race")
    end

    def envelope(key, *lines, status: "completed")
      ["<task_result task=\"#{key}\" status=\"#{status}\">", *lines, "</task_result>"].join("\n")
    end

    def user_texts(entries)
      entries.select { |entry| entry["role"] == "user" }.map { |entry| entry.dig("parts", 0, "text") }
    end

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

    def settle!(node, text)
      result = AgentLoops::Parks::Settle.call(node: node, trusted: true, outcome: "completed", content: text)
      assert_predicate result, :applied?
      schedule_loop!(node.agent_loop)
    end

    def fail!(node)
      result = AgentLoops::Parks::Settle.call(node: node, trusted: true, outcome: "failed", content: "could not")
      assert_predicate result, :applied?
      schedule_loop!(node.agent_loop)
    end

    def structured(node) = AgentLoops::TaskResultProjection.call(node.reload).fetch("structured_content")
end
