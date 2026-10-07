require "test_helper"

# A RACE NAMED AS A RESULT. A placed race is one step a later step may name in `results:`: the
# reader waits on the barrier alone — so nothing it names keeps a loser alive — and reads what the
# race selected when it settled (`TaskResultProjection.referenced`). Its projected result slot is
# envelope-shaped: the first selected envelope's fields at the top level, or the race's own
# failure, and `selected` beside them.
class AgentRuns::RaceResultsTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  # A reducer that names every probe waits for the slowest one, spares every loser and reads the
  # first envelope in list order. Naming the race, it runs the moment the race settles, the loser
  # is canceled, and the projected status and output describe the winner.
  test "a reader naming a race runs when the race settles, reads the winner, and the loser is canceled" do
    agent_run = seed(
      parallel(tool("fast", "read_file"), tool("slow", "read_file"), until: "any", key: "race"),
      model("pick", "results" => ["race"]),
      model("report")
    )
    start!(agent_run)
    pick = loop_node(agent_run, "pick")
    assert_equal ["race"], pick.result_from_node_keys
    assert_equal ["race"], pick.sources.map(&:node_key), "the reader waits on the barrier alone"

    settle!(loop_node(agent_run, "fast"), "fast: 200 OK (2s)")
    assert_equal "completed", loop_node(agent_run, "race").status
    assert_equal %w[canceled join_loser_canceled], loop_node(agent_run, "slow").values_at(:status, :error_key),
      "nothing but the settled barrier consumed the loser"
    assert_equal "running", pick.reload.status
    slot = AgentRuns::TaskResultProjection.slot(loop_node(agent_run, "race"))
    assert_equal "completed", slot.fetch("status")
    assert_equal "fast: 200 OK (2s)", slot.fetch("output")
    assert_equal ["fast: 200 OK (2s)"], slot.fetch("selected").map { |entry| entry.fetch("output") }
  end

  test "a starved race reads as its own failure at the top of the slot and in selected" do
    agent_run = seed(
      parallel(tool("a", "read_file"), tool("b", "read_file"), until: "any", key: "race", on_failure: "absorb"),
      model("pick", "results" => ["race"]),
      model("report")
    )
    start!(agent_run)
    fail!(loop_node(agent_run, "a"))
    fail!(loop_node(agent_run, "b"))
    assert_equal %w[failed join_starved], loop_node(agent_run, "race").values_at(:status, :error_key)
    assert_equal "running", loop_node(agent_run, "pick").status

    slot = AgentRuns::TaskResultProjection.slot(loop_node(agent_run, "race"))
    failure = { "status" => "failed", "is_error" => false, "output" => nil, "content" => nil,
                "structured_content" => nil, "error" => { "key" => "join_starved", "detail" => nil } }
    assert_equal failure.merge("selected" => [failure]), slot
  end

  test "a quorum's slot holds every selected envelope, first finisher first" do
    agent_run = seed(
      parallel(tool("a", "read_file"), tool("b", "read_file"), tool("c", "read_file"), until: 2, key: "race"),
      model("pick", "results" => ["race"]),
      model("report")
    )
    start!(agent_run)
    settle!(loop_node(agent_run, "c"), "C")
    travel 1.second
    settle!(loop_node(agent_run, "a"), "A")
    assert_equal "completed", loop_node(agent_run, "race").status
    assert_equal "running", loop_node(agent_run, "pick").status
    slot = AgentRuns::TaskResultProjection.slot(loop_node(agent_run, "race"))
    assert_equal "C", slot.fetch("output")
    assert_equal %w[C A], slot.fetch("selected").map { |entry| entry.fetch("output") }
  end

  # A FAILED RACE HANDS EVERY READER what it captured before failing, then its own failure — the
  # one selection the wait tool, detached delivery and a model step read too. The top of the slot
  # is the failure, so a reader checking the status never reads a partial winner as the
  # race's answer.
  test "a failed quorum's slot is its failure, with the partial winner selected before it" do
    agent_run = seed(
      parallel(tool("a", "read_file"), tool("b", "read_file"), tool("c", "read_file"),
        until: 2, key: "race", on_failure: "absorb"),
      model("pick", "results" => ["race"]),
      model("report")
    )
    start!(agent_run)
    settle!(loop_node(agent_run, "a"), "A")
    travel 1.second
    fail!(loop_node(agent_run, "b"))
    fail!(loop_node(agent_run, "c"))
    assert_equal %w[failed quorum_unreachable], loop_node(agent_run, "race").values_at(:status, :error_key)
    assert_equal "running", loop_node(agent_run, "pick").status

    slot = AgentRuns::TaskResultProjection.slot(loop_node(agent_run, "race"))
    assert_equal ["failed", "quorum_unreachable"], [slot["status"], slot.dig("error", "key")]
    assert_equal [["completed", "A"], ["failed", nil]], slot["selected"].map { |envelope| envelope.values_at("status", "output") }
  end

  test "a nested race is followed to its winners" do
    agent_run = seed(
      parallel(parallel(tool("a", "read_file"), tool("b", "read_file"), until: "any", key: "inner"),
        tool("c", "read_file"), until: "any", key: "outer"),
      model("pick", "results" => ["outer"]),
      model("report")
    )
    start!(agent_run)
    settle!(loop_node(agent_run, "b"), "B")
    assert_equal %w[completed completed], %w[inner outer].map { |key| loop_node(agent_run, key).status }
    assert_equal "running", loop_node(agent_run, "pick").status
    slot = AgentRuns::TaskResultProjection.slot(loop_node(agent_run, "outer"))
    assert_equal ["B"], slot.fetch("selected").map { |entry| entry.fetch("output") }
  end

  # A model step naming a race reads the winners as result material, once each — the explicit read
  # and the race-filtered ordinary one are the same row — and the selection is the one captured
  # when the race settled: a run-out loser that answers later is never read.
  test "a model naming a race reads the winner once and never a loser that answered later" do
    agent_run = seed(
      parallel(tool("fast", "read_file", "input" => { "path" => "fast" }),
        tool("slow", "read_file", "input" => { "path" => "slow" }), until: "any", losers: "run_out", key: "race"),
      model("reader", "results" => ["race"]),
      model("final")
    )
    start!(agent_run)
    settle!(loop_node(agent_run, "fast"), "FAST ANSWER")
    reader = loop_node(agent_run, "reader")
    assert_equal "running", reader.status
    sealed = round_request_entries(reader).to_json
    assert_equal 1, sealed.scan("FAST ANSWER").length

    settle!(loop_node(agent_run, "slow"), "SLOW ANSWER")
    texts = AgentRuns::InputComposition.call(node: reader.reload, input: reader.input_value)
      .elements.map { |element| element.parts.first.text }
    assert_includes texts, "<task_result task=\"fast\" status=\"completed\">\n" \
      "<call>read_file {\"path\":\"fast\"}</call>\nFAST ANSWER\n</task_result>"
    assert_equal 1, texts.join.scan("FAST ANSWER").length
    refute_includes texts.join, "SLOW ANSWER"
  end

  # A RETRIED LOSER re-runs the same row, so the race's answer stays the selection it captured when
  # it settled: the loser's late answer after a person's retry is never read through the race.
  test "retrying a failed race loser does not turn its late answer into a winner" do
    agent_run = seed(
      parallel(tool("fast", "read_file", "input" => { "path" => "fast" }),
        tool("slow", "read_file", "input" => { "path" => "slow" }), until: "any", losers: "run_out", key: "race"),
      model("reader", "results" => ["race"]),
      model("final")
    )
    start!(agent_run)
    settle!(loop_node(agent_run, "fast"), "FAST ANSWER")
    fail!(loop_node(agent_run, "slow"))
    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "slow", acting_user: @human
    ))
    assert_predicate retried, :accepted?, retried.outcome.inspect
    schedule_loop!(agent_run)
    settle!(loop_node(agent_run, "slow"), "RECOVERED LATE ANSWER")
    assert_equal "completed", loop_node(agent_run, "slow").status

    reader = loop_node(agent_run, "reader")
    assert_equal %w[fast], AgentRuns::TaskResultProjection.tips(agent_run, [loop_node(agent_run, "race")]).map(&:node_key)
    texts = AgentRuns::InputComposition.call(node: reader, input: reader.input_value)
      .elements.map { |element| element.parts.first.text }.join
    assert_includes texts, "FAST ANSWER"
    refute_includes texts, "RECOVERED LATE ANSWER"
  end

  # THE BATCH HISTORY READER reads a round's `results` as its request did: a history re-rendered
  # for a later round or handed to the summariser (`InputComposition.material_by_round`, the
  # compaction's delivered material) reads a race named as a result as what it selected — the
  # winner, once — never as the join row.
  test "the history reader renders a race named as a result as its winner, never the join row" do
    agent_run = seed(
      parallel(tool("fast", "read_file", "input" => { "path" => "fast" }),
        tool("slow", "read_file", "input" => { "path" => "slow" }), until: "any", key: "race"),
      model("reader", "results" => ["race"]),
      model("final")
    )
    start!(agent_run)
    settle!(loop_node(agent_run, "fast"), "FAST ANSWER")
    run_loop_round!(agent_run, sse_success("fast answered first"))
    reader = loop_node(agent_run, "reader")
    assert_equal "completed", reader.status

    delivered = AgentRuns::InputComposition.delivered_sources_by_round([reader]).fetch(reader.id)
    assert_equal ["fast"], delivered.map { |tip, _boundary| tip.node_key }, "the winner once; the join row is no material"
    texts = AgentRuns::InputComposition.material_by_round([reader]).fetch(reader.id).map { |message| message.parts.first.text }
    assert_equal ["<task_result task=\"fast\" status=\"completed\">\n<call>read_file {\"path\":\"fast\"}</call>\n" \
                  "FAST ANSWER\n</task_result>"], texts
  end

  # A model step naming a FAILED race reads the race's one selection too — the partial winner, then
  # the race's failure — the reading a result task, the wait tool and detached delivery share.
  test "a model naming a failed quorum reads its partial winner, then its failure" do
    agent_run = seed(
      parallel(tool("a", "read_file", "input" => { "path" => "a" }), tool("b", "read_file", "input" => { "path" => "b" }),
        tool("c", "read_file", "input" => { "path" => "c" }), until: 2, key: "race", on_failure: "absorb"),
      model("reader", "results" => ["race"]),
      model("final")
    )
    start!(agent_run)
    settle!(loop_node(agent_run, "a"), "A ANSWER")
    travel 1.second
    fail!(loop_node(agent_run, "b"))
    fail!(loop_node(agent_run, "c"))
    assert_equal %w[failed quorum_unreachable], loop_node(agent_run, "race").values_at(:status, :error_key)

    reader = loop_node(agent_run, "reader")
    texts = AgentRuns::InputComposition.call(node: reader, input: reader.input_value)
      .elements.map { |element| element.parts.first.text }
    winner = texts.index("<task_result task=\"a\" status=\"completed\">\n<call>read_file {\"path\":\"a\"}</call>\n" \
                         "A ANSWER\n</task_result>")
    failure = texts.index { |text| text.start_with?("<task_result task=\"race\" status=\"failed\">\nquorum_unreachable") }
    refute_nil winner, texts.inspect
    refute_nil failure, texts.inspect
    assert_operator winner, :<, failure, "the partial winner first, then the failure"
    assert_equal 1, texts.join.scan("A ANSWER").length, "the winner is rendered once"
  end

  test "a continuation beside a race keeps both result references and hides its child" do
    agent_run = seed(
      parallel(tool("a", "read_file"), tool("b", "read_file"), until: "any", key: "race"),
      tool("program", "read_file"),
      model("reader", "results" => %w[race program]),
      model("final")
    )
    start!(agent_run)
    settle!(loop_node(agent_run, "a"), "A")
    parent = loop_node(agent_run, "program")
    append_children!(parent, [AgentRuns::Tasks::Step::Tool.new(key: "child", name: "read_file", route: { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id })])
    settle!(loop_node(agent_run, "child"), "INTERNAL")
    assert_equal "queued", loop_node(agent_run, "reader").status
    settle!(parent.reload, "FINAL VALUE")

    reader = loop_node(agent_run, "reader")
    assert_equal %w[race program], reader.result_from_node_keys
    texts = user_texts(round_request_entries(reader))
    assert_includes texts, envelope("program", "<call>read_file {}</call>", "FINAL VALUE")
    refute_includes texts.join, "INTERNAL"
  end

  # A race that selected nothing — a person's resolving cancel stops it before it settles — is read
  # as its own row, never as an empty slot.
  test "a race that selected nothing is read as itself" do
    agent_run = seed(
      parallel(tool("a", "read_file"), tool("b", "read_file"), until: "any", key: "race"),
      model("report")
    )
    race = loop_node(agent_run, "race")
    race.update_columns(status: "canceled", failure_resolution: "canceled", completed_at: Time.current)

    assert_equal [race], AgentRuns::TaskResultProjection.referenced(race)
    slot = AgentRuns::TaskResultProjection.slot(race)
    assert_equal "canceled", slot["status"]
    assert_equal [slot.except("selected")], slot["selected"]
    leaf = loop_node(agent_run, "a")
    assert_equal [leaf], AgentRuns::TaskResultProjection.referenced(leaf)
    refute AgentRuns::TaskResultProjection.slot(leaf).key?("selected"), "a leaf's slot is its envelope alone"
  end

  # A MODEL NAMING A RACE OF ARM EXITS reads what the race selected: the result task it selected, once —
  # never a loser's, canceled, queued or answering later, and never the winning arm's own tool.
  test "a model naming a race of arm exits is delivered the winner's result task and never a canceled loser" do
    agent_run = seed(wrapped_race, model("report", "results" => ["race"]))
    start!(agent_run)
    settle!(loop_node(agent_run, "fast"), "FAST")
    settle!(loop_node(agent_run, "wrap-fast"), '{"host":"fast","output":"FAST"}')

    assert_equal %w[canceled join_loser_canceled], loop_node(agent_run, "wrap-slow").values_at(:status, :error_key)
    report = loop_node(agent_run, "report")
    assert_equal "running", report.status
    texts = user_texts(round_request_entries(report))
    assert_equal [envelope("wrap-fast", '<call>read_file {"path":"verdict-fast"}</call>', '{"host":"fast","output":"FAST"}'), "p"], texts
    refute_includes texts.join, 'task="wrap-slow"'
    refute_includes texts.join, "join_loser_canceled"
  end

  # A MIXED RACE: a tool winner is the race's selection like any other exit, and renders once.
  test "a mixed race's tool winner is delivered once and the losing arm's result task never" do
    agent_run = seed(mixed_race, model("report", "results" => ["race"]))
    start!(agent_run)
    settle!(loop_node(agent_run, "a"), "A")

    assert_equal "canceled", loop_node(agent_run, "sb").status
    report = loop_node(agent_run, "report")
    assert_equal "running", report.status
    assert_equal [envelope("a", '<call>read_file {"path":"a"}</call>', "A"), "p"],
      user_texts(round_request_entries(report))
  end

  test "a mixed race's result task winner is delivered without its arm's tool, and the losing tool never" do
    agent_run = seed(mixed_race, model("report", "results" => ["race"]))
    start!(agent_run)
    settle!(loop_node(agent_run, "b"), "B")
    settle!(loop_node(agent_run, "sb"), "B")

    assert_equal "canceled", loop_node(agent_run, "a").status
    assert_equal [envelope("sb", "<call>read_file {}</call>", "B"), "p"],
      user_texts(round_request_entries(loop_node(agent_run, "report"))), "the selection alone"
  end

  # A MODEL WINNER BEHIND A MAINLINE: the reader continues the mainline and reads the race it names —
  # the winning branch once, through the result path, carrying its brief as every model result a
  # step reads does.
  test "a model winner behind a mainline renders once through the result path" do
    agent_run = seed(model("r0"),
      parallel([model("m", "prompt" => "approach M")],
        [tool("t", "read_file"), tool("s", "read_file")],
        until: "any", key: "race"),
      model("report", "results" => ["race"]))
    start!(agent_run)
    run_loop_round!(agent_run, sse_success("R0 ANSWER"))
    run_loop_round!(agent_run, sse_success("M ANSWER"))

    assert_equal "canceled", loop_node(agent_run, "s").status
    report = loop_node(agent_run, "report")
    assert_equal "running", report.status
    entries = round_request_entries(report)
    tail = entries.drop(entries.rindex { |entry| entry["role"] == "assistant" } + 1)
    assert_equal [envelope("m", "<prompt>approach M</prompt>", "Mock: M ANSWER"), "p"], user_texts(tail)
  end

  test "a run-out loser's result task that completes later is never read" do
    agent_run = seed(wrapped_race(losers: "run_out"), model("report", "results" => ["race"]))
    start!(agent_run)
    settle!(loop_node(agent_run, "fast"), "FAST")
    settle!(loop_node(agent_run, "wrap-fast"), '{"host":"fast","output":"FAST"}')
    report = loop_node(agent_run, "report")
    assert_equal "running", report.status
    refute_includes user_texts(round_request_entries(report)).join, 'task="wrap-slow"',
      "the loser's result task is still queued when the race settles"

    settle!(loop_node(agent_run, "slow"), "SLOW")
    settle!(loop_node(agent_run, "wrap-slow"), '{"host":"slow","output":"SLOW"}')
    assert_equal "completed", loop_node(agent_run, "wrap-slow").status
    texts = AgentRuns::InputComposition.call(node: report.reload, input: report.input_value)
      .elements.map { |element| element.parts.first.text }
    refute_includes texts.join, 'task="wrap-slow"', "a result task that answered after the race settled is never read"
  end

  # A FAILED RACE OF ARM EXITS hands the reader naming it what it captured before failing, then
  # its own failure; the arms' tools and result tasks are read through the race, never as themselves.
  test "a failed quorum of arm exits hands its reader the partial winner, then the race's failure" do
    arms = %w[a b c].map do |key|
      [tool(key, "read_file", "input" => { "path" => key }), tool("s#{key}", "read_file")]
    end
    agent_run = seed(parallel(*arms, until: 2, key: "race", on_failure: "absorb"), model("report", "results" => ["race"]))
    start!(agent_run)
    settle!(loop_node(agent_run, "a"), "A")
    settle!(loop_node(agent_run, "sa"), "A")
    travel 1.second
    fail!(loop_node(agent_run, "b"))
    fail!(loop_node(agent_run, "c"))
    assert_equal %w[failed quorum_unreachable], loop_node(agent_run, "race").values_at(:status, :error_key)

    report = loop_node(agent_run, "report")
    texts = AgentRuns::InputComposition.call(node: report, input: report.input_value)
      .elements.map { |element| element.parts.first.text }
    assert_equal ['<task_result task="sa" status="completed">', '<task_result task="race" status="failed">', "p"],
      texts.map { |text| text.lines.first.chomp }
    assert_equal envelope("race", "quorum_unreachable", status: "failed"), texts[-2]
  end

  test "a race inside a continuation keeps its follower's named result and no inherited history" do
    agent_run = seed(tool("program", "read_file"), model("report"))
    start!(agent_run)
    parent = loop_node(agent_run, "program")
    append_children!(parent, [
      AgentRuns::Tasks::Step::Parallel.new(key: "race", until: "any", members: [
        [AgentRuns::Tasks::Step::Tool.new(key: "fast", name: "read_file", route: { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id }), AgentRuns::Tasks::Step::Tool.new(key: "fast-verdict", name: "read_file", route: { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id })],
        [AgentRuns::Tasks::Step::Tool.new(key: "slow", name: "read_file", route: { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id }), AgentRuns::Tasks::Step::Tool.new(key: "slow-verdict", name: "read_file", route: { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id })],
      ]),
      AgentRuns::Tasks::Step::Model.new(key: "follower", model: MOCK_MODEL, prompt: "report the winner", results: ["race"]),
    ])

    follower = loop_node(agent_run, "follower")
    assert_equal ["race"], follower.result_from_node_keys
    assert_nil follower.input_from_node_keys
    settle!(loop_node(agent_run, "fast"), "FAST")
    settle!(loop_node(agent_run, "fast-verdict"), "WINNER")
    assert_includes user_texts(round_request_entries(follower.reload)).join, "WINNER"
    assert_equal "canceled", loop_node(agent_run, "slow-verdict").status
  end

  # An authored envelope ending on the race carries nothing into the next append: a later append
  # names the race by its key and reads it as a result — never as material, which the door would
  # refuse.
  test "an authored envelope ending on a race of arm exits is grown by a model that names the race" do
    agent_run = seed(wrapped_race)
    start!(agent_run)
    grow!(agent_run, model("report", "results" => ["race"]))

    assert_equal ["race"], loop_node(agent_run, "report").result_from_node_keys
    assert_nil loop_node(agent_run, "report").input_from_node_keys
  end

  # THE BATCH HISTORY READER reads a named race as the request did: the winner's result task as a result,
  # never the winning arm's tool — what the summariser and a later history render.
  test "the history reader renders a named race as its selection alone" do
    agent_run = seed(wrapped_race, model("report", "results" => ["race"]), model("final"))
    start!(agent_run)
    settle!(loop_node(agent_run, "fast"), "FAST")
    settle!(loop_node(agent_run, "wrap-fast"), '{"host":"fast","output":"FAST"}')
    run_loop_round!(agent_run, sse_success("fast won"))
    report = loop_node(agent_run, "report")
    assert_equal "completed", report.status

    delivered = AgentRuns::InputComposition.delivered_sources_by_round([report]).fetch(report.id)
    assert_equal [["wrap-fast", false]], delivered.map { |tip, boundary| [tip.node_key, boundary] }
  end

  private

    # Two probes, each wrapped by a result task that ends its arm — `[probe, verdict]` per host, raced:
    # the shape the race cells' floor models write.
    def wrapped_race(**over)
      arms = %w[fast slow].map do |host|
        [tool(host, "read_file", "input" => { "path" => host }),
         tool("wrap-#{host}", "read_file", "input" => { "path" => "verdict-#{host}" })]
      end
      parallel(*arms, until: "any", key: "race", **over)
    end

    def mixed_race
      parallel(tool("a", "read_file", "input" => { "path" => "a" }),
        [tool("b", "read_file", "input" => { "path" => "b" }), tool("sb", "read_file")],
        until: "any", key: "race")
    end

    def envelope(key, *lines, status: "completed")
      ["<task_result task=\"#{key}\" status=\"#{status}\">", *lines, "</task_result>"].join("\n")
    end

    def user_texts(entries)
      entries.select { |entry| entry["role"] == "user" }.map { |entry| entry.dig("parts", 0, "text") }
    end

    def append_children!(parent, steps)
      request = { "kind" => "steps", "input" => steps.map(&:to_h) }
      parent.task_operations.create!(operation_key: "children", kind: "steps", request: request,
        request_digest: Nexus::CanonicalJson.digest(request), position: 1,
        response: { "receipt" => { "task_keys" => steps.map(&:key), "result_task_keys" => steps.map(&:key) } })
      appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
        agent_run: parent.agent_run, steps: steps, origin: "model",
        tip: AgentRuns::Tasks::Tip.seed("branch"), expansion_parent: parent, child_work: true
      ))
      assert_predicate appended, :applied?, appended.errors.inspect
      schedule_loop!(parent.agent_run)
    end

    def start!(agent_run)
      assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      )), :accepted?
      schedule_loop!(agent_run)
    end

    def settle!(node, text)
      result = AgentRuns::Parks::Settle.call(node: node, trusted: true, outcome: "completed", content: text)
      assert_predicate result, :applied?
      schedule_loop!(node.agent_run)
    end

    def fail!(node)
      result = AgentRuns::Parks::Settle.call(node: node, trusted: true, outcome: "failed", content: "could not")
      assert_predicate result, :applied?
      schedule_loop!(node.agent_run)
    end
end
