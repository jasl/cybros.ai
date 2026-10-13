require "test_helper"
require "support/gallery/shapes"
require "support/gallery/thread"

# THE GALLERY'S PREDICATES, PROVED ON PAPER BEFORE A PAID RUN. Each of the nine rows is handed a
# hand-drawn `(graph, tasks, events)` triple in its expected shape and must answer `true`; each is
# then handed a WRONG-shape triple and must answer a String naming why — so a predicate that
# silently accepts everything, or one that reads a field the route does not serve, fails here and
# not after ten minutes of model time. The triples are the route's vocabulary to the letter: node
# `{key, kind, status, visibility, deliverable, mainline?, error_key?, join?}` (`mainline` on every model
# node — the kernel's mark), edge `{from, to, structural}`, the loop row's task rows joined with `tool_input`,
# the feed's items as `{type, payload}`. THE KERNEL'S SPELLING throughout: a round's calls carry its
# CONTINUATION's number — `r1` makes `r2t0`, and `r2` reads it — so the thread each drawing encodes
# (`Gallery.thread_of`) is pinned beside its predicate.
class GalleryShapesTest < Minitest::Test
  G = E2E::Gallery

  def test_nine_shapes_with_unique_ids
    ids = G::SHAPES.map(&:id)
    assert_equal 9, ids.size
    assert_equal ids.uniq, ids
    assert_equal %i[compaction_delegate], G::SHAPES.select(&:delegate?).map(&:id)
    assert_same G.find(:linear), G::SHAPES.first
    assert_nil G.find(:handoff), "no handoff row: declined"
    G::SHAPES.each do |shape|
      assert_kind_of String, shape.expected
      assert_kind_of Proc, shape.predicate
      assert_kind_of Hash, shape.files
    end
  end

  # THE DETACHED-RECEIPT TEXT NAMES ITS TOOL (Gate 3 F4): "a background
  # task" alone reads as `start_process` — a correct reading of the owner's
  # 2026-09-02 definition — and both models took it; the shape is a `task`
  # branch, so the text says `task` and says not `start_process`, as every
  # other shape names what it drives.
  def test_the_detached_receipt_text_names_the_delegate_task_tool
    text = G.find(:detached_receipt).task
    assert_includes text, "`task` tool"
    assert_includes text, "not `start_process`"
    assert_includes text, "ruby test/all.rb", "the suite it hands over is the mail project's"
    assert_includes text, "Do not wait for the suite before you reply."
  end

  # A ROUND KEY IS ONLY A KEY: a task branch's own rounds are counted on the loop's one counter, so
  # the waited branch's `r3` is keyed like the mainline's `r2` — the mainline is the kernel's mark.
  def test_round_key_mainline_and_branch_root_pins
    assert G.round_key?("r1")
    assert G.round_key?("r12t3")
    refute G.round_key?("r2t0-model-1")
    refute G.round_key?("check-1")
    assert G.round_key?("r3")
    assert_equal %w[r1 r2], G.mainline_keys(WAITED_GRAPH), "r3 is the branch's round, marked mainline: false"
    assert G.branch_root?("r2t0-model-1")
    assert G.branch_root?("r3t2-ask-1")
    refute G.branch_root?("r2t0-model-2")
    refute G.branch_root?("r2t0")
    assert_equal "r2t0", G.call_of("r2t0-parallel-1")
    assert_nil G.call_of("r2")
    assert_nil G.call_of("summary")
  end

  def test_every_predicate_is_green_on_its_own_shape
    GREEN.each do |id, triple|
      assert_equal true, G.find(id).predicate.call(*triple), "#{id} refused its own shape"
    end
    assert_equal GREEN.keys.sort, G::SHAPES.map(&:id).sort, "every row has a hand-drawn green triple"
  end

  def test_every_predicate_names_why_on_a_wrong_shape
    RED.each do |id, (triple, expected_reason)|
      answer = G.find(id).predicate.call(*triple)
      assert_kind_of String, answer, "#{id} accepted a wrong shape"
      assert_match expected_reason, answer
    end
    assert_equal RED.keys.sort, G::SHAPES.map(&:id).sort, "every row has a wrong-shape triple"
  end

  def test_a_fan_of_task_calls_is_red_with_the_finding
    answer = G.fan_join?(LINEAR_GRAPH, [tool("r2t0", "delegate_task"), tool("r2t1", "delegate_task")], [])
    assert_equal "r2t0 placed 0 tasks and no step reads two model members; r2t1 placed 0 tasks and no step reads two model members", answer
  end

  # `wait: true` splices the branch under the call's continuation (its
  # head), so r2 is reachable from the root — through the branch's own
  # rounds when it has them.
  def test_a_waited_task_branch_is_not_detached
    answer = G.detached_receipt?(WAITED_GRAPH, [tool("r2t0", "delegate_task")], MAIL_EVENTS)
    assert_match(/the model waited/, answer)
    unrooted = G.detached_receipt?(LINEAR_GRAPH, [tool("r2t0", "delegate_task")], MAIL_EVENTS)
    assert_match(/no task branch was opened/, unrooted)
  end

  def test_the_brake_reads_the_fan_signature_off_the_joined_rows
    varied = BRAKE_TASKS.map { |row| row["key"] == "r3t0" ? row.merge("tool_input" => { "command" => "cat status.txt; true" }) : row }
    assert_match(/not identical/, G.repeat_brake?(BRAKE_GRAPH, varied, BRAKE_EVENTS))
    assert_equal [["bash", "{\"command\":\"cat status.txt\"}"]], G.fan_signature(BRAKE_TASKS, "r1")
  end

  # The kernel refuses a rotation too, but the shape's claim is the identical call: a stretch whose
  # fans differ is not the brake this task measures, and one fan is no stretch.
  def test_a_stretch_whose_fans_differ_is_not_the_brake_and_one_fan_is_no_stretch
    rotating = BRAKE_TASKS.map do |row|
      row["kind"] == "tool_task" ? row.merge("tool_input" => { "command" => "cat #{%w[a b c][row["key"][/\d+/].to_i % 3]}.txt" }) : row
    end
    assert_match(/the preceding fans are not identical/, G.repeat_brake?(BRAKE_GRAPH, rotating, BRAKE_EVENTS))
    single = BRAKE_TASKS.reject { |row| row["kind"] == "tool_task" && row["key"] != "r10t0" }
    assert_match(/fewer than two fans precede r10/, G.repeat_brake?(BRAKE_GRAPH, single, BRAKE_EVENTS))
  end

  # ── the drawings ──────────────────────────────────────────────────────

  # A model node carries the kernel's mark (true unless drawn `false`); an
  # await and a join are hidden by the kernel's defaults, as drawn here.
  def self.n(key, kind, status: "completed", deliverable: false, error_key: nil, join: nil, mainline: nil,
             visibility: nil, result_from: nil)
    { "key" => key, "kind" => kind, "status" => status,
      "visibility" => visibility || (%w[await_task join_task].include?(kind) ? "hidden" : "visible"),
      "deliverable" => deliverable,
      "mainline" => (kind == "model_task" ? mainline.nil? || mainline : nil),
      "error_key" => error_key, "join" => join, "result_from" => result_from }.compact
  end

  # An edge drawn `[from, to, false]` is a named read or an `after:` wait — the route's
  # `structural: false`; a plain pair is placement.
  def self.graph(nodes, edges)
    { "nodes" => nodes,
      "edges" => edges.map { |from, to, structural| { "from" => from, "to" => to, "structural" => structural }.compact },
      "mermaid" => "flowchart TD" }
  end

  def self.tool(key, name, after: nil, input: {}, status: "completed")
    { "key" => key, "kind" => "tool_task", "status" => status, "tool_name" => name, "after" => after, "tool_input" => input }.compact
  end

  # A round's row as the trace serves it: the refusal rides `error`
  # ({key, detail}), which the graph node carries as `error_key` alone.
  def self.round(key, status: "completed", error: nil)
    { "key" => key, "kind" => "model_task", "status" => status, "error" => error }.compact
  end

  def self.event(type, payload) = { "type" => type, "payload" => payload }

  # The thread a drawing must encode: mainline rows as `[key, calls, branches]`
  # and the rounds under each branch root.
  def self.thread(rows, branches = {})
    { "mainline" => rows.map { |key, calls, roots| { "key" => key, "calls" => calls, "branches" => roots } },
      "branches" => branches }
  end

  def n(...) = self.class.n(...)
  def graph(...) = self.class.graph(...)
  def tool(...) = self.class.tool(...)

  LINEAR_GRAPH = graph(
    [n("r1", "model_task"), n("r2t0", "tool_task"), n("r2", "model_task"), n("r3t0", "tool_task"),
     n("r3", "model_task", deliverable: true)],
    [%w[r1 r2t0], %w[r2t0 r2], %w[r2 r3t0], %w[r3t0 r3]]
  )
  LINEAR_TASKS = [tool("r2t0", "write", after: ["r1"]), tool("r3t0", "bash", after: ["r2"])].freeze

  FAN_GRAPH = graph(
    [n("r1", "model_task"), n("r2t0", "tool_task"),
     n("r2t0-model-1", "model_task", mainline: false), n("r2t0-model-2", "model_task", mainline: false),
     n("r2t0-model-3", "model_task", mainline: false), n("r2t0-model-4", "model_task", mainline: false),
     n("r2", "model_task", deliverable: true)],
    [%w[r1 r2t0], %w[r2t0 r2t0-model-1], %w[r2t0 r2t0-model-2], %w[r2t0 r2t0-model-3],
     %w[r2t0-model-1 r2t0-model-4], %w[r2t0-model-2 r2t0-model-4], %w[r2t0-model-3 r2t0-model-4],
     %w[r2t0-model-4 r2], %w[r2t0 r2]]
  )
  # The same fan as a race: the join row between the members and the merge.
  RACE_GRAPH = graph(
    [n("r1", "model_task"), n("r2t0", "tool_task"),
     n("r2t0-model-1", "model_task", mainline: false), n("r2t0-model-2", "model_task", status: "canceled", mainline: false),
     n("r2t0-parallel-1", "join_task", join: { "until" => "any", "losers" => "cancel" }),
     n("r2t0-model-3", "model_task", mainline: false), n("r2", "model_task", deliverable: true)],
    [%w[r1 r2t0], %w[r2t0 r2t0-model-1], %w[r2t0 r2t0-model-2],
     %w[r2t0-model-1 r2t0-parallel-1], %w[r2t0-model-2 r2t0-parallel-1],
     %w[r2t0-parallel-1 r2t0-model-3], %w[r2t0-model-3 r2], %w[r2t0 r2]]
  )
  FAN_TASKS = [tool("r2t0", "code", after: ["r1"])].freeze

  # The route's ownership mark on a drawn node.
  def self.placed(node, parent) = node.merge("expansion_parent" => parent)

  # A call's own tool and model, the member's continuation round and its call hung under the
  # member, and a stage that placed a tool and a stage, which placed a model.
  STAGED_TOOL = "01a0cb6b-25b2-7457-acfe-e21d7c97fdf8".freeze
  STAGED_STAGE = "01a0cb6b-25b2-73e8-9799-1ad425d00390".freeze
  STAGED_MODEL = "01a0cb6b-27f7-77eb-aeb1-3d69f6a67d66".freeze
  PLACED_GRAPH = graph(
    [n("r1", "model_task"), placed(n("r2t0", "tool_task"), "r1"),
     placed(n("r2t0-tool-1", "tool_task"), "r2t0"), placed(n("r2t0-model-1", "model_task", mainline: false), "r2t0"),
     placed(n("r3t0", "tool_task"), "r2t0-model-1"), placed(n("r3", "model_task", mainline: false), "r2t0-model-1"),
     placed(n("r2t0-script-1", "tool_task"), "r2t0"),
     placed(n(STAGED_TOOL, "tool_task"), "r2t0-script-1"), placed(n(STAGED_STAGE, "tool_task"), "r2t0-script-1"),
     placed(n(STAGED_MODEL, "model_task", mainline: false), STAGED_STAGE),
     placed(n("r2", "model_task", deliverable: true), "r1")],
    [%w[r1 r2t0], %w[r2t0 r2], %w[r2t0 r2t0-tool-1], %w[r2t0-tool-1 r2t0-model-1], %w[r2t0-model-1 r3t0], %w[r3t0 r3],
     %w[r2t0-model-1 r2t0-script-1], ["r2t0-script-1", STAGED_TOOL], [STAGED_TOOL, STAGED_STAGE], [STAGED_STAGE, STAGED_MODEL]]
  )
  # A stage that placed three reviews and the merge that reads them: the call's fan, keyed UUIDv7.
  STAGED_REVIEWS = %w[01a0cb93-1c2e-7a10-8a52-6d0f41c1e001 01a0cb93-1c2e-7a10-8a52-6d0f41c1e002
                      01a0cb93-1c2e-7a10-8a52-6d0f41c1e003].freeze
  STAGED_MERGE = "01a0cb93-1c2e-7a10-8a52-6d0f41c1e004".freeze
  STAGED_FAN_GRAPH = graph(
    [n("r1", "model_task"), placed(n("r2t0", "tool_task"), "r1"), placed(n("r2t0-script-1", "tool_task"), "r2t0"),
     *[*STAGED_REVIEWS, STAGED_MERGE].map { |key| placed(n(key, "model_task", mainline: false), "r2t0-script-1") },
     placed(n("r2", "model_task", deliverable: true), "r1")],
    [%w[r1 r2t0], %w[r2t0 r2], %w[r2t0 r2t0-script-1], *STAGED_REVIEWS.map { |key| ["r2t0-script-1", key] },
     *STAGED_REVIEWS.map { |key| [key, STAGED_MERGE] }, ["r2t0-script-1", "r2"], [STAGED_MERGE, "r2"]]
  )

  ASK_GRAPH = graph(
    [n("r1", "model_task"), n("r2t0", "tool_task"), n("r2t0-ask-1", "await_task"), n("r2", "model_task"),
     n("r3t0", "tool_task"), n("r3", "model_task", deliverable: true)],
    [%w[r1 r2t0], %w[r2t0 r2], %w[r2t0 r2t0-ask-1], %w[r2t0-ask-1 r2], %w[r2 r3t0], %w[r3t0 r3]]
  )
  ASK_EVENTS = [event("attention_required", { "reason" => "awaiting_human", "blocked_task_keys" => ["r2t0-ask-1"] })].freeze

  HALT_GRAPH = graph(
    [n("gate-1", "await_task", status: "timed_out", error_key: "await_timeout"),
     n("gate-2", "await_task"), n("work", "model_task", deliverable: true)],
    [%w[gate-1 work], %w[gate-2 work]]
  )

  # The summarizer `k1` hangs under the round it repairs — off the mainline
  # (a kernel summarizer is a branch-marked model task), never a call.
  def self.compaction_graph(kind)
    summarizer = kind == "model_task" ? n("k1", kind, mainline: false) : n("k1", kind)
    graph(
      [n("r1", "model_task"), n("r2t0", "tool_task"), n("r2", "model_task"), n("r3t0", "tool_task"),
       summarizer, n("r3", "model_task"), n("r4t0", "tool_task"), n("r4", "model_task", deliverable: true)],
      [%w[r1 r2t0], %w[r2t0 r2], %w[r2 r3t0], %w[r3t0 r3], %w[k1 r3], %w[r3 r4t0], %w[r4t0 r4]]
    )
  end

  def self.compaction_events(mode)
    [event("context_compacted", { "mode" => mode, "trigger" => "manual", "task_key" => "r3", "summary_task_key" => "k1",
                                  "run_public_id" => "loop-1" })]
  end

  KERNEL_GRAPH = compaction_graph("model_task")
  DELEGATE_GRAPH = compaction_graph("tool_task")
  SLEEP_TASKS = [tool("r2t0", "bash", after: ["r1"], input: { "command" => "sleep 20" }),
                 tool("r3t0", "bash", after: ["r2"], input: { "command" => "sleep 20" }),
                 tool("r4t0", "bash", after: ["r3"], input: { "command" => "printf done > done.txt" })].freeze
  DELEGATE_TASKS = (SLEEP_TASKS + [tool("k1", "summarize_history", after: nil)]).freeze

  # Each round the gate plants names its attempt's check and hold — the rows of an earlier append,
  # read by key — so the kernel draws a reference edge from the check beside the hold's placement.
  UNTIL_GRAPH = graph(
    [n("r1", "model_task"), n("r2t0", "tool_task"), n("r2", "model_task"),
     n("check-1", "tool_task"), n("hold-1", "await_task"), n("work-2", "model_task", result_from: %w[check-1 hold-1]),
     n("check-2", "tool_task"), n("hold-2", "await_task"),
     n("summary", "model_task", deliverable: true, result_from: %w[check-2 hold-2])],
    [%w[r1 r2t0], %w[r2t0 r2], %w[r2 check-1], %w[check-1 hold-1], %w[hold-1 work-2], ["check-1", "work-2", false],
     %w[work-2 check-2], %w[check-2 hold-2], %w[hold-2 summary], ["check-2", "summary", false]]
  )

  # The 2026-09-09 trace on deepseek: the root hangs under the call, the
  # branch's own bash round is keyed r3t0/r3 (mainline-looking keys off the
  # loop-global counter, marked `false`), nothing in the branch reaches
  # r2, the call's continuation, and the receipt's wake `w1` continues the
  # mainline as the deliverable.
  MAIL_GRAPH = graph(
    [n("r1", "model_task"), n("r2t0", "tool_task"), n("r2t1", "tool_task"), n("r2", "model_task"),
     n("r2t0-model-1", "model_task", mainline: false), n("r3t0", "tool_task"), n("r3", "model_task", mainline: false),
     n("w1", "model_task", deliverable: true)],
    [%w[r1 r2t0], %w[r1 r2t1], %w[r2t0 r2], %w[r2t1 r2], %w[r2t0 r2t0-model-1], %w[r2t0-model-1 r3t0], %w[r3t0 r3],
     %w[r2 w1]]
  )
  MAIL_TASKS = [tool("r2t0", "delegate_task", after: ["r1"], input: { "prompt" => "run ruby test/all.rb" }),
                tool("r2t1", "bash", after: ["r1"], input: { "command" => "ls lib | wc -l" })].freeze
  MAIL_EVENTS = [
    event("turn_status", { "run_public_id" => "loop-1", "run_status" => "completed" }),
    event("input_accepted", { "origin" => "task_result", "kind" => "direct_reply", "delivery_mode" => "queue",
                              "run_public_id" => "loop-1", "task_key" => "r2t0" }),
    event("turn_status", { "run_public_id" => "loop-2", "run_status" => "running" }),
    event("turn_status", { "run_public_id" => "loop-2", "run_status" => "completed" }),
  ].freeze
  # The same call WAITED: the branch is spliced under the continuation.
  WAITED_GRAPH = graph(
    [n("r1", "model_task"), n("r2t0", "tool_task"), n("r2t0-model-1", "model_task", mainline: false),
     n("r3t0", "tool_task"), n("r3", "model_task", mainline: false), n("r2", "model_task", deliverable: true)],
    [%w[r1 r2t0], %w[r2t0 r2], %w[r2t0 r2t0-model-1], %w[r2t0-model-1 r3t0], %w[r3t0 r3], %w[r3 r2]]
  )

  # The brake's drawing: ten mainline rounds, the first nine each fanning the identical `cat status.txt`
  # (r1 makes r2t0), and r10, having read the ninth, refused.
  BRAKE_GRAPH = graph(
    [n("r1", "model_task"),
     *(2..9).flat_map { |i| [n("r#{i}t0", "tool_task"), n("r#{i}", "model_task")] },
     n("r10t0", "tool_task"), n("r10", "model_task", status: "failed", error_key: G::EXPANSION_REFUSED)],
    (1..9).flat_map { |i| [["r#{i}", "r#{i + 1}t0"], ["r#{i + 1}t0", "r#{i + 1}"]] }
  )
  BRAKE_TASKS = ((1..9).map { |i| tool("r#{i + 1}t0", "bash", after: ["r#{i}"], input: { "command" => "cat status.txt" }) } +
    [round("r10", status: "failed", error: { "key" => G::EXPANSION_REFUSED, "detail" => G::REPEAT_LOOP })]).freeze
  BRAKE_EVENTS = [event("attention_required", { "reason" => "halt_failure", "blocked_task_keys" => ["r10"] })].freeze

  GREEN = {
    linear: [LINEAR_GRAPH, LINEAR_TASKS, []],
    fan_join: [FAN_GRAPH, FAN_TASKS, []],
    ask_human: [ASK_GRAPH, [tool("r2t0", "ask", after: ["r1"])], ASK_EVENTS],
    halt_retry: [HALT_GRAPH, [], []],
    compaction_kernel: [KERNEL_GRAPH, SLEEP_TASKS, compaction_events("kernel")],
    compaction_delegate: [DELEGATE_GRAPH, DELEGATE_TASKS, compaction_events("delegate")],
    until_gate: [UNTIL_GRAPH, [], []],
    detached_receipt: [MAIL_GRAPH, MAIL_TASKS, MAIL_EVENTS],
    repeat_brake: [BRAKE_GRAPH, BRAKE_TASKS, BRAKE_EVENTS],
  }.freeze

  # The wrong shape and the sentence it must answer with.
  RED = {
    linear: [[FAN_GRAPH, FAN_TASKS, []], /outside the mainline/],
    fan_join: [[LINEAR_GRAPH, LINEAR_TASKS, []], /no step reads two model members/],
    ask_human: [[LINEAR_GRAPH, LINEAR_TASKS, []], /never called `ask`/],
    halt_retry: [[ASK_GRAPH, [], []], /authored keys are missing/],
    compaction_kernel: [[KERNEL_GRAPH, SLEEP_TASKS, compaction_events("delegate")], /mode "delegate", expected kernel/],
    compaction_delegate: [[KERNEL_GRAPH, SLEEP_TASKS, compaction_events("delegate")], /k1 is model_task, expected tool_task/],
    until_gate: [[LINEAR_GRAPH, [], []], /missing from the ladder/],
    detached_receipt: [[LINEAR_GRAPH, LINEAR_TASKS, []], /no background task was started/],
    repeat_brake: [[LINEAR_GRAPH, LINEAR_TASKS, []], /no round was refused repeat_call_loop/],
  }.freeze

  # ── the threads ─────────────────────────────────────────── What each drawing encodes as a
  # THREAD: linear — rounds only, `r2t0` under `r2`; fan_join — one root with the members and the
  # merge under the expansion; ask_human — NO root, the ask call among the calls; halt_retry — the
  # authored mainline with no calls; the two compactions — `k1` on no page; until_gate — the ladder's
  # model steps on the mainline, its checks calls of no round; detached_receipt — the root under
  # `r2t0`, its chain under the expansion only, the `w1` wake on the mainline; repeat_brake — the
  # refused round a mainline row like any other.
  THREADS = {
    linear: thread([["r1", [], []], ["r2", ["r2t0"], []], ["r3", ["r3t0"], []]]),
    fan_join: thread([["r1", [], []], ["r2", ["r2t0"], ["r2t0"]]],
      "r2t0" => %w[r2t0-model-1 r2t0-model-2 r2t0-model-3 r2t0-model-4]),
    ask_human: thread([["r1", [], []], ["r2", ["r2t0"], []], ["r3", ["r3t0"], []]]),
    halt_retry: thread([["work", [], []]]),
    compaction_kernel: thread([["r1", [], []], ["r2", ["r2t0"], []], ["r3", ["r3t0"], []], ["r4", ["r4t0"], []]]),
    compaction_delegate: thread([["r1", [], []], ["r2", ["r2t0"], []], ["r3", ["r3t0"], []], ["r4", ["r4t0"], []]]),
    until_gate: thread([["r1", [], []], ["r2", ["r2t0"], []], ["work-2", [], []], ["summary", [], []]]),
    detached_receipt: thread([["r1", [], []], ["r2", %w[r2t0 r2t1], ["r2t0"]], ["w1", [], []]],
      "r2t0" => %w[r2t0-model-1 r3]),
    repeat_brake: thread([["r1", [], []], *(2..10).map { |i| ["r#{i}", ["r#{i}t0"], []] }]),
  }.freeze

  def test_every_drawing_encodes_the_thread_its_row_promises
    THREADS.each do |id, expected|
      assert_equal expected, G.thread_of(GREEN.fetch(id).first), "#{id}'s drawing folds to a different thread"
    end
    assert_equal THREADS.keys.sort, G::SHAPES.map(&:id).sort, "every row has its thread pinned"
  end

  # A race's join row is hidden and crossed: the merge is still under the
  # prefix. A waited branch reaches the continuation and STOPS there: the
  # mainline round is never a branch's row.
  def test_a_race_and_a_waited_branch_fold_under_their_call_and_stop_at_the_mainline
    assert_equal self.class.thread([["r1", [], []], ["r2", ["r2t0"], ["r2t0"]]],
      "r2t0" => %w[r2t0-model-1 r2t0-model-2 r2t0-model-3]), G.thread_of(RACE_GRAPH)
    assert_equal self.class.thread([["r1", [], []], ["r2", ["r2t0"], ["r2t0"]]],
      "r2t0" => %w[r2t0-model-1 r3]), G.thread_of(WAITED_GRAPH)
  end

  def test_a_drawing_whose_model_node_lacks_the_mark_is_refused
    unmarked = graph([{ "key" => "r1", "kind" => "model_task", "status" => "completed", "visibility" => "visible",
                        "deliverable" => true }], [])
    error = assert_raises(ArgumentError) { G.thread_of(unmarked) }
    assert_match(/r1 carries no mainline mark/, error.message)
  end

  # THE LADDER HANDS THE CHECK ON BY NAME: nothing crosses an append by position, so a round the
  # gate planted without naming its attempt's check and hold never read the output it must fix.
  def test_a_ladder_round_that_does_not_name_its_check_and_hold_is_refused
    unnamed = ->(round) { UNTIL_GRAPH["nodes"].map { |node| node["key"] == round ? node.except("result_from") : node } }
    assert_match(/work-2 does not name check-1 and hold-1: results \[\]/,
      G.until_gate?(graph(unnamed.("work-2"), UNTIL_GRAPH["edges"].map(&:values)), [], []))
    assert_match(/summary does not name check-2 and hold-2/,
      G.until_gate?(graph(unnamed.("summary"), UNTIL_GRAPH["edges"].map(&:values)), [], []))
  end

  def test_an_owned_model_is_a_branch_without_a_dependency_from_the_code_task
    child = "01a107b7-d09d-7347-95fb-0bd57738b3c3"
    own = graph([
      n("r1", "model_task"), n("r2t0", "tool_task"),
      n(child, "model_task", mainline: false).merge("expansion_parent" => "r2t0"),
      n("r2", "model_task", deliverable: true),
    ], [%w[r1 r2t0], %w[r2t0 r2]])
    assert_equal self.class.thread([["r1", [], []], ["r2", ["r2t0"], ["r2t0"]]], "r2t0" => [child]), G.thread_of(own)
  end

  def test_a_race_reads_as_a_fan_through_its_join_row
    assert_equal true, G.fan_join?(RACE_GRAPH, FAN_TASKS, [])
  end

  # THE NODES A CALL PLACED are the kernel's ownership mark, `expansion_parent`: the call's own
  # steps and, recursively, what each of its script stages placed (keyed UUIDv7, never under the
  # call's prefix), and never a member model's own rounds or their tool calls, which hang under
  # the member. A drawing none of whose nodes carries the mark reads by the call's key prefix.
  def test_a_call_placed_its_steps_and_what_its_stages_placed_never_a_members_rounds
    placed = G.placed_by(PLACED_GRAPH, "r2t0").map { |node| node["key"] }
    assert_equal ["r2t0-tool-1", "r2t0-model-1", "r2t0-script-1", STAGED_TOOL, STAGED_STAGE, STAGED_MODEL], placed
    assert_empty G.placed_by(PLACED_GRAPH, "r3t0"), "a member's own call placed nothing"
    assert_equal %w[r2t0-model-1 r2t0-model-2 r2t0-model-3 r2t0-model-4], G.placed_by(FAN_GRAPH, "r2t0").map { |node| node["key"] },
      "an unmarked drawing reads by the call's prefix"
  end

  def test_a_fan_a_stage_placed_is_the_calls_fan
    assert_equal STAGED_MERGE, G.fan_under(STAGED_FAN_GRAPH, "r2t0")&.fetch("key")
    assert_equal true, G.fan_join?(STAGED_FAN_GRAPH, FAN_TASKS, [])
    unmerged = graph(STAGED_FAN_GRAPH["nodes"], STAGED_FAN_GRAPH["edges"].map(&:values).reject { |_, to| to == STAGED_MERGE })
    assert_equal "r2t0 placed 5 tasks and no step reads two model members", G.fan_join?(unmerged, FAN_TASKS, [])
  end

  # The kernel writes the brake as a REFUSAL: `error.key` is the expansion
  # refusal, `error.detail` the brake (ApplyStepResult → FailNode), and the
  # graph node carries the key alone — so a predicate reading
  # `error_key == "repeat_call_loop"` off the graph would never fire.
  def test_the_brake_is_read_off_the_task_rows_error_detail_not_the_graph_key
    on_graph_only = BRAKE_TASKS.reject { |row| row["key"] == "r10" }
    assert_match(/no round was refused repeat_call_loop/, G.repeat_brake?(BRAKE_GRAPH, on_graph_only, BRAKE_EVENTS))
    other_refusal = BRAKE_TASKS.map do |row|
      row["key"] == "r10" ? row.merge("error" => { "key" => G::EXPANSION_REFUSED, "detail" => "task_key_too_long" }) : row
    end
    assert_match(/no round was refused repeat_call_loop/, G.repeat_brake?(BRAKE_GRAPH, other_refusal, BRAKE_EVENTS))
    undrawn = graph(BRAKE_GRAPH["nodes"].reject { |n| n["key"] == "r10" }, [])
    assert_match(/is not on the graph/, G.repeat_brake?(undrawn, BRAKE_TASKS, BRAKE_EVENTS))
  end

  def test_a_prune_or_a_wall_is_not_the_manual_door
    events = [self.class.event("context_compacted", { "mode" => "prune", "trigger" => "wall", "task_key" => "r3" })]
    assert_match(/no manual compaction; triggers: \["wall"\]/, G.compaction?(KERNEL_GRAPH, SLEEP_TASKS, events, mode: "kernel"))
  end
end
