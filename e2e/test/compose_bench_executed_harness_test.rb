require_relative "executed_plan_scenarios"
require_relative "compose_bench_harness"
require "support/task_bench/declared_set"

# THE EXECUTED READING: the picture scored on the plan the kernel placed under a compose call, read
# off the graph route, with every script stage contracted but one whose value reaches the caller.
# Two oracles pin the contraction: on a plan with no stage it is the static lowering of the script,
# and on a plan whose stages are result-free it is the static lowering with each stage's expansion
# inlined (`Shape.inline`), up to the names of the steps a stage placed. The plans are
# independently authored scripts and route graphs, limited to the dataflow each test exercises.
class ComposeBenchExecutedHarnessTest < Minitest::Test
  include ComposeBenchHarness

  Executed = E2E::ComposeBench::Executed
  Scoring = E2E::ComposeBench::Scoring
  PLANS = ExecutedPlanScenarios.all.freeze
  # The runner tool contract these authored plans use.
  DECLARED = E2E::TaskBench::DeclaredSet.names(style: "nexus").freeze
  EXACT = { "exact_edges" => true, "exact_reads" => true, "silent" => [] }.freeze
  # The keys the kernel gives the steps a stage places.
  UUIDS = (1..5).map { |i| "00000000-0000-7000-8000-00000000020#{i}" }.freeze
  # Steps drawn under the call `r1t0`: three greps; O7's three [fetch, normalise] pairs and their waits.
  GREP_KEYS = %w[r1t0-tool-1 r1t0-tool-2 r1t0-tool-3].freeze
  GREPS = GREP_KEYS.map { |key| [key, "tool_task", "r1t0", []] }.freeze
  NORMALISERS = %w[r1t0-model-1 r1t0-model-2 r1t0-model-3].freeze
  PAIRS = [*GREPS, *NORMALISERS.zip(GREP_KEYS).map { |model, tool| [model, "model_task", "r1t0", [tool]] }].freeze
  PAIR_WAITS = GREP_KEYS.zip(NORMALISERS).freeze

  # THE KINDS ARE THE KERNEL'S: every task kind a node of the route can carry, read off the node
  # classes themselves, has its word in the reading.
  def test_the_kind_map_is_the_kernels_task_kinds
    kinds = Dir[File.expand_path("../../nexus/app/models/agent_loop_nodes/*.rb", __dir__)].map do |path|
      File.read(path, encoding: "UTF-8")[/self\.task_kind = "(\w+)"/, 1]
    end
    assert_equal kinds.sort, Executed::KINDS.keys.sort
  end

  # THE TWO ORACLES, over every authored plan they reach: with no stage, the route graph
  # is the script's static lowering; with every stage result-free, it is the static lowering with
  # each stage's expansion inlined — one graph under the names the kernel gave the steps. The four
  # plans with no stage carry what the fold and the kernel's reads must survive: a member's own
  # rounds, a reader naming a member's continuation, `results:` wiring, a race's join.
  def test_the_executed_graph_is_the_static_lowering_with_result_free_stages_inlined
    reached = PLANS.select { |_, fixture| inline_plan(fixture).then { |i| i.opaque.empty? && i.refused.empty? && i.valued.empty? } }
    assert_equal %w[member_continuation_read member_continuation_rounds normalise_in_the_fetch normalise_tools race results_wiring
                    whole_plan_wrapper wrapped_rendezvous],
      reached.keys.sort
    reached.each do |name, fixture|
      assert Executed.same_graph?(Shape.lower(inline_plan(fixture).steps), Executed.lower(plan_of(fixture))), name
    end
    stage_free = reached.select { |_, fixture| plan_of(fixture).stage_free? }
    assert_equal %w[member_continuation_read member_continuation_rounds normalise_in_the_fetch normalise_tools race results_wiring],
      stage_free.keys.sort
    stage_free.each_value do |fixture|
      assert Executed.same_graph?(lower(fixture["script"], params: fixture["params"] || {}), Executed.lower(plan_of(fixture)))
    end
  end

  # ONE GRAPH UNDER ANOTHER NAMING, and nothing looser: renamed keys still match; a lost read, an
  # extra wait, a race of another count or a step of another kind does not.
  def test_same_graph_matches_a_renaming_and_refuses_a_near_miss
    graph = lower(CANONICAL["O7b"])
    renamed = rename(graph) { |key| "r9t9-#{key}" }
    assert Executed.same_graph?(graph, renamed)
    lost_read = graph.with(nodes: graph.nodes.map { |node| node.key == "model-2" ? node.with(reads: node.reads.drop(1)) : node })
    refute Executed.same_graph?(graph, lost_read)
    refute Executed.same_graph?(graph, graph.with(edges: graph.edges + [%w[tool-1 model-2]]))
    refute Executed.same_graph?(graph, graph.with(nodes: graph.nodes.map { |node| node.key == "tool-1" ? node.with(kind: "ask") : node }))
    race = lower(CANONICAL["O3"])
    refute Executed.same_graph?(race, race.with(nodes: race.nodes.map { |node| node.kind == "join" ? node.with(race: 2) : node }))
  end

  # A MEMBER'S OWN ROUNDS FOLD INTO IT: each review ran rounds of its own (keyed `rN`, hung under
  # the review), and the verdict reads the reviews' continuations — which are the reviews: the
  # kernel re-points a name of a model that used tools at its final round. A step reads nothing
  # else: the lint chain's report names its re-check alone and reads it alone, never the fix's
  # continuation before it.
  def test_a_members_rounds_fold_into_the_member
    graph = Executed.lower(plan_of(PLANS["member_continuation_rounds"]))
    assert_equal %w[r2t0-model-1 r2t0-model-2 r2t0-model-3 r2t0-model-4], graph.keys
    assert_equal %w[r2t0-model-1 r2t0-model-2 r2t0-model-3], graph.node("r2t0-model-4").reads.sort
    assert_equal({ "exact_edges" => true, "exact_reads" => true, "silent" => [] }, Objectives.find("O1").picture.score(graph))
    background = Executed.lower(plan_of(PLANS["member_continuation_read"]))
    assert_equal %w[r2t0-tool-3], background.node("r2t0-model-3").reads, "the report reads the re-check it names"
    assert graph.nodes.all? { |node| node.positional.empty? }, "no step a compose call placed reads by position"
  end

  # NESTED STAGES CONTRACT, OUTERMOST FIRST: the wrapper hands its place to the three greps it
  # placed, the stage reading them to the read it placed, that one's stage to the edit, and the
  # last stage — a value nothing in the plan waits on or reads — stays a node reading the edit and
  # both checks. The read is the first tool a stage decided after the greps answered, which O2's
  # picture admits in its edit's place, and past it O2's tail takes the edit, both checks and the
  # closing value as the chain they extend: the plan is O2's.
  def test_nested_stages_contract_into_what_they_placed
    fixture = PLANS["nested_stages"]
    plan = plan_of(fixture)
    graph = Executed.lower(plan)
    described = Scoring.describe(graph, labels: Executed.labels(plan))
    greps = %w[script-1/tool-1 script-1/tool-2 script-1/tool-3]
    read = "script-1/script-1/tool-1"
    edit, check, recheck = %w[tool-1 tool-2 tool-3].map { |kind| "script-1/script-1/script-1/#{kind}" }
    value = "script-1/script-1/script-1/script-1"
    assert_equal [*[*greps, read, edit, check, recheck].map { |key| "#{key}:tool" }, "#{value}:script"], described["nodes"]
    assert_equal [*greps.map { |grep| "#{grep}->#{read}" }, "#{read}->#{edit}", "#{edit}->#{check}", "#{check}->#{recheck}",
                  *[edit, check, recheck].map { |step| "#{step}->#{value}" }].sort,
      described["edges"].sort
    assert_equal [edit, check, recheck], described.dig("reads", value)
    assert_equal EXACT, Objectives.find("O2").picture.score(graph)
  end

  # AN EXPANDED STAGE'S CONSUMER WAITS ON THE TAIL, never on what the stage waited on: the kernel's
  # splice gives the consumer an edge from the expansion's tail and re-points its read there, so
  # the stage's own edge to the consumer goes with the stage, and only the expansion's root takes
  # over the stage's wait on the lint.
  def test_an_expanded_stages_consumer_waits_on_the_tail
    tail = "00000000-0000-7000-8000-000000000302"
    head = "00000000-0000-7000-8000-000000000301"
    nodes = [["r1t0-tool-1", "tool_task", "r1t0", []], ["r1t0-script-1", "script_task", "r1t0", []],
             [head, "tool_task", "r1t0-script-1", []], [tail, "model_task", "r1t0-script-1", [head]],
             ["r1t0-model-1", "model_task", "r1t0", [tail, "r1t0-tool-1"]]]
    graph = { "nodes" => nodes.map { |key, kind, parent, reads| { "key" => key, "kind" => kind, "expansion_parent" => parent, "input_from" => reads } },
              "edges" => [%w[r1t0 r1t0-tool-1], %w[r1t0-tool-1 r1t0-script-1], ["r1t0-script-1", head], [head, tail],
                          %w[r1t0-script-1 r1t0-model-1], [tail, "r1t0-model-1"]].map { |from, to| { "from" => from, "to" => to } } }
    lowered = Executed.lower(Executed.plan(graph, "r1t0"))
    assert_equal [["r1t0-tool-1", head], [head, tail], [tail, "r1t0-model-1"]].sort, lowered.edges.sort
    assert_equal ["r1t0-tool-1", tail].sort, lowered.node("r1t0-model-1").reads.sort
  end

  # A VALUE STAGE SOMETHING CONSUMES IS TRANSPARENT UNLESS THE PICTURE TAKES IT; A STAGE THAT FAILED
  # OR LOST A RACE IS TRANSPARENT ALWAYS. A value stage in each race arm hands the race its probe:
  # the winning arm's stage completed, so it stays a `script` node the reading names transparent,
  # and O3's picture, which has no step there, contracts it. The authored winner names nothing, so
  # it reads its prompt alone and is blind; drawn naming the race, its read of the three tags is a
  # read of the three probes, O3 exactly. The losing arms' stages computed nothing and are gone. A
  # stage that failed at run time placed nothing either: the three greps before it are all that ran.
  def test_a_consumed_value_stage_is_transparent_unless_the_picture_takes_it
    fixture = PLANS["value_stages_in_a_race"]
    plan = plan_of(fixture)
    race = Executed.lower(plan)
    assert_equal %w[tool tool script tool join model], race.nodes.map(&:kind)
    assert_equal %w[r2t0-script-2], plan.transparent
    assert_equal ["blind_model"], Objectives.find("O3").picture.score(race, transparent: plan.transparent)["silent"]
    named = plan_of(with_nodes(fixture) { |node| node["kind"] == "model_task" ? node.merge("result_from" => ["r2t0-parallel-1"]) : node })
    assert_equal EXACT, Objectives.find("O3").picture.score(Executed.lower(named), transparent: named.transparent)
    failed = plan_of(PLANS["failed_stage"])
    assert_equal %w[completed failed], failed.stages.map { |key| failed.nodes.fetch(key)["status"] }
    graph = Executed.lower(failed)
    assert_equal %w[tool tool tool], graph.nodes.map(&:kind)
    assert_empty graph.edges
  end

  # A WHOLE-PLAN STAGE THAT FAILED placed nothing: the executed graph is empty, and it reads as the
  # steps it misses — never as a suite something waited on.
  def test_a_failed_whole_plan_stage_reads_as_the_steps_it_missed
    wrapper = PLANS["whole_plan_wrapper"]
    failed = wrapper.merge("graph" => wrapper["graph"].merge(
      "nodes" => wrapper["graph"]["nodes"].reject { |node| node["expansion_parent"] == "r2t0-script-1" }
        .map { |node| node["key"] == "r2t0-script-1" ? node.merge("status" => "failed") : node },
      "edges" => wrapper["graph"]["edges"].select { |edge| edge["from"] == "r2t0" }
    ))
    objective = Objectives.find("O3")
    static = Scoring.score(objective, script: wrapper["script"], params: wrapper["params"], tool_names: DECLARED)
    read = Executed.reading(objective, static, plan_of(failed))
    assert_equal "executed", read["reading"]
    assert_empty read["graph"]["nodes"]
    assert_equal %w[missing_join missing_steps], read["silent"]
  end

  # WHAT A STAGE WROTE INTO A PROMPT IS CREDITED WHEN THE GRAPH CAN TELL: the stage read the three
  # greps and placed the one model that edits; the kernel handed that model nothing, and the values
  # the stage wrote into its prompt came from what it read — the ultracode idiom — so the model is
  # credited with the greps, O2 exactly, the credit on the record. A stage that placed two models
  # could have written any of its values into either prompt: neither is credited, and the picture
  # names them `stage_fed`, never blind and never a pass.
  def test_the_one_model_a_stage_fed_is_credited_with_the_stages_reads
    plan = plan_of(PLANS["stage_placed_model"])
    graph = Executed.lower(plan)
    assert_equal [%w[r2t0-tool-1 r2t0-tool-2 r2t0-tool-3]], graph.reads.values, "the one model is credited with what its stage read"
    assert_equal EXACT, Objectives.find("O2").picture.score(graph)
    labels = Executed.labels(plan)
    credited = { "script-1/model-1" => %w[tool-1 tool-2 tool-3] }
    assert_equal credited, Executed.stage_reads(plan).to_h { |key, read| [labels.fetch(key), read.map { |source| labels.fetch(source) }] }
    fixture = PLANS["stage_placed_model"]
    static = Scoring.score(Objectives.find("O2"), script: fixture["script"], params: fixture["params"], tool_names: DECLARED)
    read = Executed.reading(Objectives.find("O2"), static, plan)
    assert_equal credited, read["stage_fed"]
    assert read["first_time_right"], read.inspect

    several = drawn([*GREPS, ["r1t0-script-1", "script_task", "r1t0", GREP_KEYS], [UUIDS[0], "model_task", "r1t0-script-1", []],
                     [UUIDS[1], "model_task", "r1t0-script-1", []]],
      [*GREP_KEYS.map { |grep| [grep, "r1t0-script-1"] }, ["r1t0-script-1", UUIDS[0]], ["r1t0-script-1", UUIDS[1]]])
    fed = Executed.stage_fed(several)
    assert_equal({}, fed.credited)
    assert_equal UUIDS.first(2), fed.several
    silent = Objectives.find("O2").picture.score(Executed.lower(several), stage_fed: fed.several)["silent"]
    assert_includes silent, "stage_fed"
    refute_includes silent, "blind_model"
    assert_includes Objectives.find("O2").picture.score(Executed.lower(several))["silent"], "blind_model",
      "a model no stage fed that reads nothing is blind"
  end

  # A CREDIT IS NO NAME, AND IT IS THE MODEL'S OWN STAGE'S: a stage that read the three greps and a
  # fourth tool and placed the one editing model credits it with all four — more than O2's edit
  # reads, which is `stage_fed`, never `over_read_named`, since the model's author named nothing.
  # A model a stage placed under a stage that read nothing is credited with nothing, whatever the
  # stage above that one read: the credit is what its own stage was handed.
  def test_a_credit_that_over_reads_is_stage_fed_and_only_the_own_stage_credits
    extra = [*GREPS, ["r1t0-tool-4", "tool_task", "r1t0", []],
             ["r1t0-script-1", "script_task", "r1t0", [*GREP_KEYS, "r1t0-tool-4"]], [UUIDS[0], "model_task", "r1t0-script-1", []]]
    over = drawn(extra, [*GREP_KEYS.map { |grep| [grep, "r1t0-script-1"] }, %w[r1t0-tool-4 r1t0-script-1], ["r1t0-script-1", UUIDS[0]]])
    assert_equal({ UUIDS[0] => [*GREP_KEYS, "r1t0-tool-4"] }, Executed.stage_fed(over).credited)
    silent = Objectives.find("O2").picture.score(Executed.lower(over))["silent"]
    assert_includes silent, "stage_fed"
    refute_includes silent, "over_read_named"

    nested = drawn([*GREPS, ["r1t0-script-1", "script_task", "r1t0", GREP_KEYS], [UUIDS[0], "script_task", "r1t0-script-1", []],
                    [UUIDS[1], "model_task", UUIDS[0], []]],
      [*GREP_KEYS.map { |grep| [grep, "r1t0-script-1"] }, ["r1t0-script-1", UUIDS[0]], [UUIDS[0], UUIDS[1]]])
    assert_equal({}, Executed.stage_fed(nested).credited, "the model's own stage read nothing")
    assert_equal({ UUIDS[1] => GREP_KEYS }, Executed.stage_reads(nested), "though the stage above it could have handed it the greps")
  end

  # O2'S EDIT MAY BE A TOOL A STAGE DECIDED ON THE GREPS: the tool has no prompt, so what it read is
  # what the stages above it read — the stage it hangs under, and any stage that handed it data
  # down through `params`. This stage reads the three greps,
  # places a `perl -pi` rename and closes on a value stage reporting it, the ending the compose text
  # recommends; the same edit two stages down, under a result-free stage, is the same dataflow.
  def test_an_edit_tool_a_stage_decided_after_the_greps_is_o2s_edit
    picture = Objectives.find("O2").picture
    graph = Executed.lower(plan_of(PLANS["stage_decided_edit"]))
    assert_equal %w[r2t0-tool-1 r2t0-tool-2 r2t0-tool-3], graph.node("r2t0-edit").reads
    assert_equal EXACT, picture.score(graph)

    one = drawn([*GREPS, ["r1t0-script-1", "script_task", "r1t0", GREP_KEYS], [UUIDS[0], "tool_task", "r1t0-script-1", []]],
      [*GREP_KEYS.map { |grep| [grep, "r1t0-script-1"] }, ["r1t0-script-1", UUIDS[0]]])
    assert_equal EXACT, picture.score(Executed.lower(one))
    deeper = drawn([*GREPS, ["r1t0-script-1", "script_task", "r1t0", GREP_KEYS], [UUIDS[0], "script_task", "r1t0-script-1", []],
                    [UUIDS[1], "tool_task", UUIDS[0], []]],
      [*GREP_KEYS.map { |grep| [grep, "r1t0-script-1"] }, ["r1t0-script-1", UUIDS[0]], [UUIDS[0], UUIDS[1]]])
    assert_equal EXACT, picture.score(Executed.lower(deeper)), "the edit hangs under the stage that read the greps"
  end

  # A STAGE THAT RETURNED A VALUE WHERE O2'S EDIT GOES, AND THAT NOTHING CONSUMED, placed no edit:
  # it read the three greps, completed and placed nothing, and nothing after it could have decided
  # the edit on what it read, so the edit's place is held by a stage.
  # A stage that placed the edit it decided is O2's edit, exact beside it
  # (`test_an_edit_tool_a_stage_decided_after_the_greps_is_o2s_edit`).
  def test_a_value_stage_where_o2s_edit_goes_is_edit_as_stage
    held = drawn([*GREPS, ["r1t0-script-1", "script_task", "r1t0", GREP_KEYS]], GREP_KEYS.map { |grep| [grep, "r1t0-script-1"] })
    assert_empty held.transparent, "nothing consumes the value"
    assert_equal ["edit_as_stage"], Objectives.find("O2").picture.score(Executed.lower(held), transparent: held.transparent)["silent"]
  end

  # AN EDIT WRITTEN BEFORE THE GREPS ANSWERED IS STILL A TOOL: a result-free wrapper placed the greps
  # and the edit together, so nothing the edit's input came from had read them.
  def test_an_edit_a_stage_wrote_before_the_greps_answered_is_edit_as_tool
    wrapper = drawn([["r1t0-script-1", "script_task", "r1t0", []], *UUIDS.first(3).map { |key| [key, "tool_task", "r1t0-script-1", []] },
                     [UUIDS[3], "tool_task", "r1t0-script-1", []]],
      [*UUIDS.first(3).map { |key| ["r1t0-script-1", key] }, *UUIDS.first(3).map { |key| [key, UUIDS[3]] }])
    graph = Executed.lower(wrapper)
    assert_empty graph.node(UUIDS[3]).reads
    assert_equal ["edit_as_tool"], Objectives.find("O2").picture.score(graph)["silent"]
  end

  # A TOOL WHERE A PICTURE HAS ONLY A MODEL is still `edit_as_tool`, whatever its stage read: only a
  # label that admits a tool (O2's edit) takes a tool a stage decided.
  def test_a_stage_decided_tool_at_a_model_only_label_is_edit_as_tool
    o4 = drawn([["r1t0-tool-1", "tool_task", "r1t0", []], ["r1t0-tool-2", "tool_task", "r1t0", []],
                ["r1t0-script-1", "script_task", "r1t0", ["r1t0-tool-2"]], [UUIDS[0], "tool_task", "r1t0-script-1", []]],
      [["r1t0-tool-2", "r1t0-script-1"], ["r1t0-script-1", UUIDS[0]]])
    assert_equal ["edit_as_tool"], Objectives.find("O4").picture.score(Executed.lower(o4))["silent"]
  end

  # A BLIND CHECK AFTER A DECIDED EDIT makes nothing guessed: it waits on the edit and reads nothing
  # but the edit's chain, so O2's tail takes it as the verification it is — a blind step BEFORE the
  # edit stays an extra step (`test_o2s_tail_admits_a_verification_past_the_edit_and_never_a_blind_step_before_it`),
  # and so does a blind second edit in the check's place (`test_a_blind_edit_past_o2s_edit_is_an_extra_step`).
  # A picture that admits no tool counts every tool, blind or decided.
  def test_a_decided_edit_followed_by_a_blind_check_extends_the_edit
    steps = [*GREPS, ["r1t0-script-1", "script_task", "r1t0", GREP_KEYS], [UUIDS[0], "tool_task", "r1t0-script-1", []],
             ["r1t0-tool-4", "tool_task", "r1t0", []]]
    waits = [*GREP_KEYS.map { |grep| [grep, "r1t0-script-1"] }, ["r1t0-script-1", UUIDS[0]], [UUIDS[0], "r1t0-tool-4"]]
    plan = drawn(steps, waits, tools: { UUIDS[0] => "edit", "r1t0-tool-4" => "grep" })
    assert_equal EXACT, Objectives.find("O2").picture.score(Executed.lower(plan))
    guessed = drawn(steps, waits, tools: { UUIDS[0] => "edit", "r1t0-tool-4" => "edit" })
    assert_equal ["extra_steps"], Objectives.find("O2").picture.score(Executed.lower(guessed))["silent"]
    o7b = drawn([*%w[r1t0-tool-1 r1t0-tool-2 r1t0-tool-3 r1t0-tool-4].map { |key| [key, "tool_task", "r1t0", []] },
                 ["r1t0-script-1", "script_task", "r1t0", %w[r1t0-tool-2 r1t0-tool-3]], [UUIDS[0], "tool_task", "r1t0-script-1", []],
                 ["r1t0-model-1", "model_task", "r1t0", ["r1t0-tool-4", UUIDS[0]]]],
      [%w[r1t0-tool-1 r1t0-tool-4], %w[r1t0-tool-2 r1t0-script-1], %w[r1t0-tool-3 r1t0-script-1], ["r1t0-script-1", UUIDS[0]],
       %w[r1t0-tool-4 r1t0-model-1], [UUIDS[0], "r1t0-model-1"]])
    assert_includes Objectives.find("O7b").picture.score(Executed.lower(o7b))["silent"], "edit_as_tool"
  end

  # O7'S MERGE MAY BE A VALUE STAGE ON THE PLAN THAT RAN: the stage completed, placed nothing and
  # nothing reads it, so it stands as a node reading what it read. One that placed the merge model
  # is not one, and the model it placed is the merge: the one model a stage fed, credited with what
  # the stage read. A value stage after a model merge is the plan's answer and drops out.
  def test_a_value_stage_stands_for_o7s_merge_on_the_plan_that_ran
    picture = Objectives.find("O7").picture
    value = drawn([*PAIRS, ["r1t0-script-1", "script_task", "r1t0", NORMALISERS]], [*PAIR_WAITS, *NORMALISERS.map { |key| [key, "r1t0-script-1"] }])
    graph = Executed.lower(value)
    assert_equal NORMALISERS, graph.node("r1t0-script-1").reads
    assert_equal EXACT, picture.score(graph)

    placing = drawn([*PAIRS, ["r1t0-script-1", "script_task", "r1t0", NORMALISERS], [UUIDS[0], "model_task", "r1t0-script-1", []]],
      [*PAIR_WAITS, *NORMALISERS.map { |key| [key, "r1t0-script-1"] }, ["r1t0-script-1", UUIDS[0]]])
    assert_equal EXACT, picture.score(Executed.lower(placing)), "the one model the stage fed, credited with its reads"

    reduced = drawn([*PAIRS, ["r1t0-model-4", "model_task", "r1t0", NORMALISERS], ["r1t0-script-1", "script_task", "r1t0", ["r1t0-model-4"]]],
      [*PAIR_WAITS, *NORMALISERS.map { |key| [key, "r1t0-model-4"] }, %w[r1t0-model-4 r1t0-script-1]])
    assert_equal EXACT, picture.score(Executed.lower(reduced))
  end

  # O7'S NORMALISER MAY BE A VALUE STAGE ON THE PLAN THAT RAN: each per-source stage completed,
  # placed nothing and read its own fetch alone, and the merge read it — so it stays a `script`
  # node, and the picture takes it where it has a normaliser. A whole-plan stage places
  # three [fetch, value stage] pairs and a value merge reading the three.
  def test_a_per_source_value_stage_stands_for_o7s_normaliser
    fixture = PLANS["per_source_value_stages"]
    plan = plan_of(fixture)
    described = Scoring.describe(Executed.lower(plan), labels: Executed.labels(plan))
    fetches = %w[script-1/tool-1 script-1/tool-2 script-1/tool-3]
    normalisers = %w[script-1/script-1 script-1/script-2 script-1/script-3]
    assert_equal [*fetches.zip(normalisers).flat_map { |fetch, normaliser| ["#{fetch}:tool", "#{normaliser}:script"] }, "script-1/script-4:script"],
      described["nodes"]
    assert_equal normalisers.zip(fetches.map { |fetch| [fetch] }).to_h.merge("script-1/script-4" => normalisers), described["reads"]
    read = reading_of(fixture, "O7")
    assert_equal "executed", read["reading"]
    assert_equal EXACT, read.slice(*EXACT.keys)
  end

  # O7'S NORMALISER MAY BE A TOOL PLACED AFTER ITS OWN FETCH: `sh bin/normalise a` reads the file
  # `sh bin/fetch a > raw.a` wrote. A tool's input is fixed when the script is written, so what it
  # computes over is what the steps it waits on left behind, and where the picture's step computes a
  # tool reads what it waits on. This plan has three
  # [fetch, normalise] tool pairs, then a `cat` merge — the one step there the picture does not admit
  # as a tool, so the plan reads red on it; the same pairs merged by a value stage read exact.
  def test_a_normalise_tool_after_its_own_fetch_stands_for_o7s_normaliser
    fixture = PLANS["normalise_tools"]
    assert_equal ["edit_as_tool"], reading_of(fixture, "O7")["silent"], "the cat merge is a tool where the merge is pictured"
    normalisers = %w[r6t0-tool-2 r6t0-tool-4 r6t0-tool-6]
    merged = with_nodes(fixture) do |node|
      node["key"] == "r6t0-tool-7" ? node.merge("kind" => "script_task", "result_from" => normalisers) : node
    end
    assert_equal EXACT, Objectives.find("O7").picture.score(Executed.lower(plan_of(merged)))
  end

  # A NORMALISE FOLDED INTO ITS FETCH IS NO STEP OF ITS OWN: `sh bin/fetch a | awk …` is one tool,
  # so every pair misses its normaliser, however the fetch's command computes.
  def test_a_normalise_folded_into_its_fetch_is_a_missing_step
    read = reading_of(PLANS["normalise_in_the_fetch"], "O7")
    refute read["first_time_right"]
    assert_includes read["silent"], "missing_steps"
  end

  # A CONSUMED VALUE STAGE NO LABEL TAKES READS AS IT ALWAYS DID: transparent. A stage naming the file
  # the greps found, read by the edit, leaves O2 exact; so does a stage reading the race that the
  # winner reads.
  def test_a_consumed_value_stage_no_label_takes_is_transparent
    relay = drawn([*GREPS, ["r1t0-script-1", "script_task", "r1t0", GREP_KEYS], ["r1t0-model-1", "model_task", "r1t0", ["r1t0-script-1"]]],
      [*GREP_KEYS.map { |grep| [grep, "r1t0-script-1"] }, %w[r1t0-script-1 r1t0-model-1]])
    assert_equal %w[r1t0-script-1], relay.transparent
    assert_equal EXACT, Objectives.find("O2").picture.score(Executed.lower(relay), transparent: relay.transparent)

    probes = %w[r1t0-tool-1 r1t0-tool-2 r1t0-tool-3]
    race = drawn([*probes.map { |key| [key, "tool_task", "r1t0", []] }, ["r1t0-parallel-1", "join_task", "r1t0", []],
                  ["r1t0-script-1", "script_task", "r1t0", ["r1t0-parallel-1"]], ["r1t0-model-1", "model_task", "r1t0", ["r1t0-script-1"]]],
      [*probes.map { |key| [key, "r1t0-parallel-1"] }, %w[r1t0-parallel-1 r1t0-script-1], %w[r1t0-script-1 r1t0-model-1]])
    assert_equal EXACT, Objectives.find("O3").picture.score(Executed.lower(race), transparent: race.transparent)
  end

  # A WRAPPED PLAN THAT ENDS ON A VALUE READS AS THE PLAN: the whole-plan stage hands its place to
  # the reviews and the verdict it placed, and the value stage after the verdict is the plan's
  # answer — the ending the compose text recommends — so O1 reads exact.
  def test_a_wrapped_plan_ending_on_a_value_stage_reads_exact
    reviews = UUIDS.first(3)
    verdict, reducer = UUIDS.last(2)
    wrapped = drawn([["r1t0-script-1", "script_task", "r1t0", []], *reviews.map { |key| [key, "model_task", "r1t0-script-1", []] },
                     [verdict, "model_task", "r1t0-script-1", reviews], [reducer, "script_task", "r1t0-script-1", [verdict]]],
      [*reviews.map { |key| ["r1t0-script-1", key] }, *reviews.map { |key| [key, verdict] }, [verdict, reducer]])
    assert_equal EXACT, Objectives.find("O1").picture.score(Executed.lower(wrapped))
  end

  # A VALUE STAGE NAMING EVERY PROBE WAITED ON THE LOSERS THE RACE WAS WRITTEN TO ABANDON: it stands
  # where O3 has the winner and reads the race's own, and its `results:` are waits on each probe
  # that kept the losers running, so every probe completed.
  def test_a_value_stage_after_a_race_stands_for_the_winner_and_waits_on_the_losers
    probes = %w[r1t0-tool-1 r1t0-tool-2 r1t0-tool-3]
    race = drawn([*probes.map { |key| [key, "tool_task", "r1t0", []] }, ["r1t0-parallel-1", "join_task", "r1t0", []],
                  ["r1t0-script-1", "script_task", "r1t0", probes]],
      [*probes.map { |key| [key, "r1t0-parallel-1"] }, %w[r1t0-parallel-1 r1t0-script-1], *probes.map { |key| [key, "r1t0-script-1"] }])
    score = Objectives.find("O3").picture.score(Executed.lower(race))
    assert_equal({ "exact_edges" => false, "exact_reads" => true, "silent" => ["over_sync"] }, score)
  end

  # A VALUE STAGE NAMING THE RACE waits on its join alone and reads the probes its selection is
  # drawn from — the kernel's `result_from` names the join, read through its in-edges — so it stands
  # for O3's winner exactly, and nothing it names keeps a loser running.
  def test_a_value_stage_naming_the_race_stands_for_the_winner_and_waits_on_the_join_alone
    probes = %w[r1t0-tool-1 r1t0-tool-2 r1t0-tool-3]
    race = drawn([*probes.map { |key| [key, "tool_task", "r1t0", []] }, ["r1t0-parallel-1", "join_task", "r1t0", []],
                  ["r1t0-script-1", "script_task", "r1t0", ["r1t0-parallel-1"]]],
      [*probes.map { |key| [key, "r1t0-parallel-1"] }, %w[r1t0-parallel-1 r1t0-script-1]])
    graph = Executed.lower(race)
    assert_equal probes, graph.node("r1t0-script-1").reads
    assert_equal EXACT, Objectives.find("O3").picture.score(graph)
  end

  # THE ORACLE HOLDS FOR A RACE NAMED IN `results`: a stage-free plan whose model names the race is
  # the script's static lowering — the static reading reads the race's exits where the kernel's
  # `result_from` names the join.
  def test_a_model_naming_the_race_reads_one_graph_on_both_readings
    script = <<~JS
      const race = g.parallel([
        g.tool({ name: "bash", input: { command: "bin/probe alpha" } }),
        g.tool({ name: "bash", input: { command: "bin/probe bravo" } }),
        g.tool({ name: "bash", input: { command: "bin/probe charlie" } }),
      ], { until: "any" });
      g.model({ prompt: "Say which host answered first.", results: [race] });
    JS
    probes = %w[r1t0-tool-1 r1t0-tool-2 r1t0-tool-3]
    nodes = [*probes.map { |key| { "key" => key, "kind" => "tool_task" } },
             { "key" => "r1t0-parallel-1", "kind" => "join_task", "join" => { "until" => "any", "losers" => "cancel" } },
             { "key" => "r1t0-model-1", "kind" => "model_task", "input_from" => probes, "result_from" => ["r1t0-parallel-1"] }]
    graph = { "nodes" => [{ "key" => "r1t0", "kind" => "tool_task", "status" => "completed", "expansion_parent" => "r1" },
                          *nodes.map { |node| node.merge("status" => "completed", "expansion_parent" => "r1t0") }],
              "edges" => [*probes.map { |key| { "from" => key, "to" => "r1t0-parallel-1" } },
                          { "from" => "r1t0-parallel-1", "to" => "r1t0-model-1" }] }
    plan = Executed.plan(graph, "r1t0")
    assert_predicate plan, :stage_free?
    assert Executed.same_graph?(lower(script), Executed.lower(plan))
    assert_equal EXACT, Objectives.find("O3").picture.score(Executed.lower(plan))
  end

  # A RACE NESTED IN ANOTHER'S ARM IS READ THROUGH TO ITS OWN EXITS: a step naming the outer race
  # reads what the two selections are drawn from — the inner race's probes beside the outer's own —
  # and never the inner race's join, which is a barrier and no material. One transitive expansion
  # serves both readings: the executed one, whose model names the outer join in `result_from` (as a
  # step after a race whose arm ends in a stage names it without writing it), and the static one of
  # the script naming the outer race in `results:`.
  def test_a_step_naming_an_outer_race_reads_the_inner_races_exits_and_never_its_join
    script = <<~JS
      const outer = g.parallel([
        [g.parallel([
          g.tool({ name: "bash", input: { command: "bin/probe alpha" } }),
          g.tool({ name: "bash", input: { command: "bin/probe bravo" } }),
        ], { until: "any" })],
        g.tool({ name: "bash", input: { command: "bin/probe charlie" } }),
      ], { until: "any" });
      g.model({ prompt: "Say which host answered first.", results: [outer] });
    JS
    static = lower(script)
    assert_equal %w[tool-1 tool-2 tool-3], static.node("model-1").reads.sort

    probes = %w[r1t0-tool-1 r1t0-tool-2 r1t0-tool-3]
    race = { "until" => "any", "losers" => "cancel" }
    nodes = [*probes.map { |key| { "key" => key, "kind" => "tool_task" } },
             { "key" => "r1t0-parallel-1", "kind" => "join_task", "join" => race },
             { "key" => "r1t0-parallel-2", "kind" => "join_task", "join" => race },
             { "key" => "r1t0-model-1", "kind" => "model_task", "input_from" => probes, "result_from" => ["r1t0-parallel-2"] }]
    graph = { "nodes" => [{ "key" => "r1t0", "kind" => "tool_task", "status" => "completed", "expansion_parent" => "r1" },
                          *nodes.map { |node| node.merge("status" => "completed", "expansion_parent" => "r1t0") }],
              "edges" => [%w[r1t0-tool-1 r1t0-parallel-1], %w[r1t0-tool-2 r1t0-parallel-1], %w[r1t0-parallel-1 r1t0-parallel-2],
                          %w[r1t0-tool-3 r1t0-parallel-2], %w[r1t0-parallel-2 r1t0-model-1]].map { |from, to| { "from" => from, "to" => to } } }
    executed = Executed.lower(Executed.plan(graph, "r1t0"))
    assert_equal probes, executed.node("r1t0-model-1").reads.sort
    assert Executed.same_graph?(static, executed)

    exits = { "parallel-2" => %w[parallel-1 tool-3], "parallel-1" => %w[tool-1 tool-2] }
    assert_equal %w[tool-1 tool-2 tool-3 tool-9], Shape.race_reads(exits, %w[parallel-2 tool-9])
    assert_equal %w[tool-1 tool-2 tool-3], Shape.race_reads(exits, %w[parallel-2 tool-3]), "once each"
    assert_equal %w[tool-1], Shape.race_reads(exits, %w[tool-1]), "a leaf is itself"
  end

  # A LAUNCH IS READ AS NO WAIT ON WHAT IT LAUNCHED: `start_process` answers once its `wait_seconds`
  # run out (15 here, short of the fixture suite's 40 s) while the suite runs on as a process, so a
  # step after it is read as waiting on the launch, never on the suite, whatever the budget, and O4
  # reads no `suite_waited_on` off its out-edges on either reading. Its receipt is still the suite's
  # first output, so a step that names it over-reads. The suite launches beside [lint → fix],
  # followed by a report naming the launch and the fix — a plan with no
  # stage, so the two readings must still agree before the launch's waits are set apart, and the
  # record keeps them. A suite run by `bash` is waited on as ever, on both readings.
  O4_LAUNCH = <<~'JS'.freeze
    const suite = g.tool({ name: "SUITE", input: { command: "bin/rails test", wait_seconds: 15 } });
    const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
    const fix = g.model({ prompt: "Fix every offence the lint output names.", results: [lint] });
    g.parallel([suite, [lint, fix]]);
    g.model({ prompt: "Report the suite's launch and the fix.", results: [suite, fix] });
  JS

  def test_a_launch_is_no_wait_on_the_suite_and_a_step_reading_it_over_reads
    steps = [["r1t0-tool-1", "tool_task", "r1t0", []], ["r1t0-tool-2", "tool_task", "r1t0", []],
             ["r1t0-model-1", "model_task", "r1t0", ["r1t0-tool-2"]], ["r1t0-model-2", "model_task", "r1t0", %w[r1t0-tool-1 r1t0-model-1]]]
    waits = [%w[r1t0-tool-2 r1t0-model-1], %w[r1t0-tool-1 r1t0-model-2], %w[r1t0-model-1 r1t0-model-2]]
    read = o4_reading(O4_LAUNCH, steps, waits, suite: "start_process")
    assert_equal "executed", read["reading"]
    assert_equal %w[extra_steps over_read_named], read["silent"]
    assert_equal %w[extra_steps over_read_named], read.dig("static", "silent")
    assert_includes read["graph"]["edges"], "tool-1->model-2", "the record keeps the launch's wait"

    bash = o4_reading(O4_LAUNCH, steps, waits, suite: "bash")
    assert_equal "executed", bash["reading"]
    assert_equal %w[suite_waited_on extra_steps over_read_named], bash["silent"]
    assert_equal %w[suite_waited_on extra_steps over_read_named], bash.dig("static", "silent")
  end

  # A LAUNCH CHAINED BEFORE THE LINT is read as no wait too: `suite; lint; fix` with a `start_process`
  # suite leaves the lint waiting on the launch alone, so `suite_waited_on` and `over_sync` drop off
  # its out-edge, and what is left is the fix naming the launch beside the lint — `over_read_named`
  # and nothing more. The same chain with a `bash` suite waits the suite out and reads all three, on
  # both readings.
  O4_LAUNCH_CHAIN = <<~'JS'.freeze
    const suite = g.tool({ name: "SUITE", input: { command: "bin/rails test", wait_seconds: 15 } });
    const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
    g.model({ prompt: "Fix every offence the lint output names.", results: [suite, lint] });
  JS

  def test_a_launch_chained_before_the_lint_leaves_the_fix_over_reading_and_nothing_more
    steps = [["r1t0-tool-1", "tool_task", "r1t0", []], ["r1t0-tool-2", "tool_task", "r1t0", []],
             ["r1t0-model-1", "model_task", "r1t0", %w[r1t0-tool-1 r1t0-tool-2]]]
    waits = [%w[r1t0-tool-1 r1t0-tool-2], %w[r1t0-tool-2 r1t0-model-1], %w[r1t0-tool-1 r1t0-model-1]]
    launched = o4_reading(O4_LAUNCH_CHAIN, steps, waits, suite: "start_process")
    assert_equal "executed", launched["reading"]
    assert_equal %w[over_read_named], launched["silent"]
    assert_equal %w[over_read_named], launched.dig("static", "silent")

    waited = o4_reading(O4_LAUNCH_CHAIN, steps, waits, suite: "bash")
    assert_equal %w[suite_waited_on over_sync over_read_named], waited["silent"]
    assert_equal %w[suite_waited_on over_sync over_read_named], waited.dig("static", "silent")
  end

  # O2 ADMITS A VERIFICATION TAIL PAST ITS EDIT: steps after the edit that wait on it and touch only
  # its chain extend the dataflow the objective exists for, and a read a stage decided on the greps
  # takes the edit's label, the real edit and the verify after it extending it. A stage reads the
  # greps and places a `read` of the defining file, a stage under
  # it reads that and places the edit and a verify grep, and a closing value stage reads the greps and
  # the verify. A blind tool between the greps and the edit decided nothing and stays an extra step.
  def test_o2s_tail_admits_a_verification_past_the_edit_and_never_a_blind_step_before_it
    picture = Objectives.find("O2").picture
    read_first = drawn([*GREPS, ["r1t0-script-1", "script_task", "r1t0", GREP_KEYS], [UUIDS[0], "tool_task", "r1t0-script-1", []],
                        [UUIDS[1], "script_task", "r1t0-script-1", [UUIDS[0]]], [UUIDS[2], "tool_task", UUIDS[1], []],
                        [UUIDS[3], "tool_task", UUIDS[1], []], ["r1t0-script-2", "script_task", "r1t0", [*GREP_KEYS, UUIDS[3]]]],
      [*GREP_KEYS.map { |grep| [grep, "r1t0-script-1"] }, ["r1t0-script-1", UUIDS[0]], [UUIDS[0], UUIDS[1]], [UUIDS[1], UUIDS[2]],
       [UUIDS[2], UUIDS[3]], *GREP_KEYS.map { |grep| [grep, "r1t0-script-2"] }, %w[r1t0-script-1 r1t0-script-2],
       [UUIDS[1], "r1t0-script-2"], [UUIDS[3], "r1t0-script-2"]])
    assert_equal EXACT, picture.score(Executed.lower(read_first))

    blind = drawn([*GREPS, ["r1t0-tool-4", "tool_task", "r1t0", []], ["r1t0-script-1", "script_task", "r1t0", GREP_KEYS],
                   [UUIDS[0], "tool_task", "r1t0-script-1", []]],
      [*GREP_KEYS.map { |grep| [grep, "r1t0-tool-4"] }, %w[r1t0-tool-4 r1t0-script-1], *GREP_KEYS.map { |grep| [grep, "r1t0-script-1"] },
       ["r1t0-script-1", UUIDS[0]]])
    assert_equal ["extra_steps"], picture.score(Executed.lower(blind))["silent"]
  end

  # A BLIND EDIT PAST O2'S EDIT IS NO VERIFICATION: an `edit` the compose call placed itself reads
  # nothing, so it was written before the greps answered — the guessed edit O2 exists to catch, past
  # a model step that read the greps (and may only have reported them) as much as before one. The
  # trace's task rows name the tool; a blind grep in its place is the verification the tail takes.
  def test_a_blind_edit_past_o2s_edit_is_an_extra_step
    picture = Objectives.find("O2").picture
    steps = [*GREPS, ["r1t0-model-1", "model_task", "r1t0", GREP_KEYS], ["r1t0-tool-4", "tool_task", "r1t0", []]]
    waits = [*GREP_KEYS.map { |grep| [grep, "r1t0-model-1"] }, %w[r1t0-model-1 r1t0-tool-4]]
    assert_equal ["extra_steps"], picture.score(Executed.lower(drawn(steps, waits, tools: { "r1t0-tool-4" => "edit" })))["silent"]
    assert_equal EXACT, picture.score(Executed.lower(drawn(steps, waits, tools: { "r1t0-tool-4" => "grep" })))
  end

  # THE READING, merged: the executed verdict where the kernel placed a plan, the static one beside
  # it, and whether the script built — with its refusal — the static evaluation's alone. The
  # wrapper placed the race and its winner, which names nothing and reads its prompt alone; its
  # stage read nothing, so nothing is credited to it.
  def test_the_reading_is_the_executed_verdict_with_the_static_one_beside_it
    fixture = PLANS["whole_plan_wrapper"]
    objective = Objectives.find("O3")
    static = Scoring.score(objective, script: fixture["script"], params: fixture["params"], tool_names: DECLARED)
    read = Executed.reading(objective, static, plan_of(fixture))
    assert_equal "executed", read["reading"]
    assert_equal %w[blind_model], read["silent"], read.inspect
    assert_equal %w[missing_join missing_steps], read.dig("static", "silent")
    assert_equal static.slice(*Executed::VERDICT), read["static"]
    assert_equal({}, read["stage_reads"])
    assert_equal({}, read["stage_fed"])
    assert_includes read["graph"]["nodes"], "script-1/model-1:model"
    named = with_nodes(fixture) { |node| node["kind"] == "model_task" ? node.merge("result_from" => ["r2t0-parallel-1"]) : node }
    assert Executed.reading(objective, static, plan_of(named))["first_time_right"], "the winner naming its race"
    assert_equal "static", Executed.reading(objective, static, plan_of(fixture.merge("call" => "r9t9")))["reading"], "no plan"
    refused = Scoring.score(objective, script: "g.model({ prompt: ", params: {}, tool_names: DECLARED)
    assert_equal refused.merge("reading" => "static"), Executed.reading(objective, refused, plan_of(fixture))
  end

  # THE HARNESS'S OWN FAULTS RAISE: a plan with no stage whose graph is not the script's static
  # lowering (the harness's copy of the lowering drifted), a read naming a stage that expanded (the
  # kernel's splice re-points such reads), an expansion that hangs off nothing, and a picture that
  # detaches a step (the route carries no detachment).
  def test_what_the_harness_cannot_read_raises
    race = PLANS["race"]
    other = Scoring.score(Objectives.find("O3"), script: CANONICAL["O1"], params: {}, tool_names: DECLARED)
    assert_raises(Executed::Drifted) { Executed.reading(Objectives.find("O3"), other, plan_of(race)) }

    wrapper = PLANS["whole_plan_wrapper"]
    reads_the_stage = with_nodes(wrapper) { |node| node["kind"] == "model_task" ? node.merge("input_from" => ["r2t0-script-1"]) : node }
    error = assert_raises(Executed::Drifted) { Executed.lower(plan_of(reads_the_stage)) }
    assert_match(/reads r2t0-script-1, a stage that placed/, error.message)
    unhung = wrapper.merge("graph" => wrapper["graph"].merge("edges" => wrapper["graph"]["edges"].reject { |edge| edge["from"] == "r2t0-script-1" }))
    assert_raises(Executed::Drifted) { Executed.lower(plan_of(unhung)) }

    detached = Objectives::Objective.new(id: "X1", slug: "detached", gate: false, text: "x", note: "x",
      picture: E2E::ComposeBench::Picture.new(nodes: { "m" => "model!" }, edges: [], reads: { "m" => [] }))
    static = Scoring.score(detached, script: 'g.model({ prompt: "x" });', params: {}, tool_names: DECLARED)
    assert_raises(Executed::Unreadable) { Executed.reading(detached, static, plan_of(race)) }
  end

  private

    def plan_of(fixture) = Executed.plan(fixture.fetch("graph"), fixture.fetch("call"))

    # The executed verdict and the static verdict over the same authored scenario.
    def reading_of(fixture, id)
      objective = Objectives.find(id)
      static = Scoring.score(objective, script: fixture["script"], params: fixture["params"], tool_names: DECLARED)
      Executed.reading(objective, static, plan_of(fixture))
    end

    # A plan drawn as the route serves one under the call `r1t0`: `[key, task kind, parent, reads]`
    # per step, every step completed, and the waits between them; `tools` names a tool step's tool,
    # as the trace's task rows do.
    def drawn(steps, waits, tools: {})
      nodes = steps.map do |key, kind, parent, reads|
        { "key" => key, "kind" => kind, "status" => "completed", "expansion_parent" => parent, "result_from" => reads }
      end
      graph = { "nodes" => [{ "key" => "r1t0", "kind" => "tool_task", "status" => "completed", "expansion_parent" => "r1" }, *nodes],
                "edges" => waits.map { |from, to| { "from" => from, "to" => to } } }
      Executed.plan(graph, "r1t0", tools: tools)
    end

    # O4's reading of a script whose SUITE is run by `suite`, on the plan drawn for it: the suite is
    # `r1t0-tool-1` and the lint, run by `bash`, is `r1t0-tool-2`.
    def o4_reading(script, steps, waits, suite:)
      objective = Objectives.find("O4")
      static = Scoring.score(objective, script: script.sub("SUITE", suite), params: {}, tool_names: DECLARED)
      Executed.reading(objective, static, drawn(steps, waits, tools: { "r1t0-tool-1" => suite, "r1t0-tool-2" => "bash" }))
    end

    def inline_plan(fixture)
      built = evaluate(fixture["script"], params: fixture["params"] || {})
      flunk "#{built.refusal}: #{built.detail}" unless built.built?
      Shape.inline(built.steps, tool_names: DECLARED)
    end

    def rename(graph)
      Shape::Graph.new(
        nodes: graph.nodes.map { |node| node.with(key: yield(node.key), reads: node.reads.map { |key| yield(key) }) },
        edges: graph.edges.map { |from, to| [yield(from), yield(to)] }
      )
    end

    def with_nodes(fixture, &block)
      fixture.merge("graph" => fixture["graph"].merge("nodes" => fixture["graph"]["nodes"].map(&block)))
    end
end
