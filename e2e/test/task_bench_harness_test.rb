$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "yaml"
require "support/task_bench"
require_relative "recording_adapter"

# THE TOOLS' SCORERS, before any money is spent: the declared set is what a rho turn declares (the
# runner's tools, the kernel's three verbs and the memory tools, rho's guideline in the
# instructions) under each STYLE ( `nexus` the plain names, `claude` `Agent` and `AskUserQuestion`,
# `codex` `spawn_agent`/`send_message` = the kernel's `spawn`/`send`, plain `task` beside them), and
# each objective's property passes the message it describes and fails the near-misses it names —
# scored on the call as the KERNEL resolves it (`resolve_call`), so one rule reads three spellings.
class TaskBenchHarnessTest < Minitest::Test
  Objectives = E2E::TaskBench::Objectives
  DeclaredSet = E2E::TaskBench::DeclaredSet

  def call(name, **arguments) = { "id" => "c", "name" => name, "arguments" => JSON.generate(arguments) }

  def declared(style = "nexus") = DeclaredSet.function_definitions(style: style)

  def test_the_declared_set_is_rhos_tools_then_the_kernels_with_the_guideline
    names = DeclaredSet.names
    assert_equal names, DeclaredSet.names(style: "nexus"), "the default style is the baseline"
    %w[read grep bash start_process code delegate_task ask spawn send status cancel memory_write].each { |name| assert_includes names, name }
    assert_equal names.index("bash") < names.index("code"), true, "the runner's tools head the prefix"
    assert_includes DeclaredSet.instructions, "You can call several tools in one message."
    definition = DeclaredSet.symbolized_definitions.find { |entry| entry.dig(:function, :name) == "delegate_task" }
    assert_equal %w[prompt], definition.dig(:function, :parameters, :required)
    assert_equal %w[nexus], E2E::TaskBench::STYLES, "the default axis is the baseline alone"
  end

  # A STYLE'S SET is rho's lowered tools then the SDK pack's `apply` (a harness-built row per style
  # word) over the kernel's live definitions, rendered by the kernel: the claude set carries
  # `Agent`/`AskUserQuestion`/`Skill` and no `task`/`ask`/`skill`;
  # the wire carries no alias fact. The runner's hidden names (the relay
  # reads, the runner's `skill`) are in no style's set — the kernel's `skill` is the one `skill` a
  # model sees, so the set the kernel compiles carries it once.
  def test_a_style_declares_rhos_tools_then_the_presets_spellings
    baseline = DeclaredSet.names
    assert_equal 1, baseline.count("skill"), "the kernel's skill, never the runner's beside it"
    assert_empty baseline & %w[files_bytes process_log], "the relay reads are announced, never declared"
    refute_nil Nexus::ToolDeclarations.refusal(DeclaredSet.function_definitions + DeclaredSet.function_definitions.last(1)),
      "the kernel refuses a doubled name: the harness set must carry each once"
    assert_nil Nexus::ToolDeclarations.refusal(DeclaredSet.function_definitions(style: "claude")),
      "the claude set is one the kernel compiles"
    claude = DeclaredSet.names(style: "claude")
    assert_equal baseline - %w[delegate_task ask skill] + %w[Agent AskUserQuestion Skill], claude
    skill = declared("claude").find { |entry| entry.dig("function", "name") == "Skill" }
    assert_equal "nexus.skill.load", skill["canonical"]
    assert_equal %w[skill], skill.dig("function", "parameters", "properties").keys, "Claude Code's {skill} maps onto name"
    assert_includes skill.dig("function", "description"), "call Skill with the exact name"
    agent = declared("claude").find { |entry| entry.dig("function", "name") == "Agent" }
    assert_equal "nexus.graph.delegate_task", agent["canonical"]
    assert_equal %w[prompt model lifetime wake run_in_background tools], agent.dig("function", "parameters", "properties").keys
    refute_includes agent.dig("function", "description"), "{{"
    wired = DeclaredSet.symbolized_definitions(style: "claude").find { |entry| entry.dig(:function, :name) == "Agent" }
    assert_equal %i[function type], wired.keys.sort, "no canonical/params reaches a provider"
    codex = DeclaredSet.names(style: "codex")
    assert_equal DeclaredSet.names - %w[ask spawn send] + %w[spawn_agent send_message], codex,
      "codex re-spells spawn and send, and plain task stays"
    send_message = declared("codex").find { |entry| entry.dig("function", "name") == "send_message" }
    assert_equal "nexus.conversation.send", send_message["canonical"]
    assert_equal %w[target agent message steer deliver_in deliver_at wake model],
      send_message.dig("function", "parameters", "properties").keys,
      "`target` (the reference's current spelling, C-S2) is the kernel's `to` (WHERE: what spawn_agent returned); " \
      "the kernel's `agent` (WHO, r6), `deliver_in`/`deliver_at` (the clock, capabilities III item 12) and " \
      "`model` (the initiator's, F-3) pass through under their own names"
    assert_equal %w[target message], send_message.dig("function", "parameters", "required")
    assert_equal Nexus::ToolRegistry.entry("send").parameters.dig("properties", "to", "description"),
      send_message.dig("function", "parameters", "properties", "target", "description"),
      "no description of rho's on the map: the kernel's `to` sentence rides under `target`"
    refute_includes send_message.inspect, "agent_id", "the V1 output field is gone"
    assert_equal DeclaredSet.names + %w[Agent AskUserQuestion Skill], DeclaredSet.names(style: "nexus+claude")
    assert_raises(ArgumentError) { DeclaredSet.names(style: "gemini") }
  end

  # THE CANDIDATE AXIS (the RUN step's text probes): a `tool_descriptions` candidate's entry joins
  # the declared set as the row's own description variant — rendered against the kernel's task
  # template and compiled by the kernel (no `alias_name_reserved`, no doubled name). The files carry
  # no entry today (kimi's `agent-without-example`, the variant without the worked example, was
  # DELETED 2026-09-16: T2 1/3 → 0/3), so the variant read here is the claude preset's own `Agent`
  # entry as a candidate of kimi's row. A `lead_hints` candidate's line rides the instructions block
  # after the tool lines, where a row's hints ride rho's lead; the sample carries the key. A
  # summarizer or tool_style candidate is refused here by kind. No candidate is on file, so the hint
  # and the word are the test's own, handed to the loader in place of the files.
  def test_a_description_candidate_joins_the_set_and_a_hint_the_instructions
    rows = E2E::AdaptationRows
    hint = E2E::AdaptationRows::Candidate.new(row_id: "kimi-k3", id: "test-hint", kind: "lead_hints", seed: "the test's own; never a file",
      payload: "A task you start without `wait: true` answers later; do not wait for it.")
    word = E2E::AdaptationRows::Candidate.new(row_id: "glm-5.3", id: "test-word", kind: "tool_style", seed: "the test's own; never a file",
      payload: ["workflow"])
    agent = E2E::AdaptationRows::Candidate.new(row_id: "kimi-k3", id: "agent-as-claude", kind: "tool_descriptions", seed: "the preset's entry",
      payload: rows.pack.presets.preset("claude").aliases.find { |spec| spec.fetch("name") == "Agent" })
    rows.stub(:candidates, { hint.key => hint, word.key => word }) do
      assert_equal [hint], rows.list("kimi-k3/test-hint", kinds: %w[lead_hints tool_descriptions])
      kind = assert_raises(ArgumentError) { rows.list(word.key, kinds: %w[lead_hints tool_descriptions]) }
      assert_match(/is a tool_style candidate; this probe reads lead_hints, tool_descriptions/, kind.message)
    end
    gone = assert_raises(ArgumentError) { rows.list("kimi-k3/agent-without-example,kimi-k3/k6-detached-fan-is-never-waited", kinds: %w[lead_hints tool_descriptions]) }
    assert_match(%r{no candidate "kimi-k3/agent-without-example"}, gone.message, "deleted, as k6 is")
    assert_equal({}, E2E::TaskBench::CANDIDATES.to_h { |c| [c.key, c] }, "no E2E_BENCH_CANDIDATES: the baseline")
    assert E2E::TaskBench::CELLS.values.all? { |cells| cells == [nil] }

    with_agent = DeclaredSet.names(style: "nexus", candidate: agent)
    assert_equal DeclaredSet.names + %w[Agent], with_agent, "the entry beside the plain task under nexus"
    entry = DeclaredSet.function_definitions(style: "nexus", candidate: agent).find { |e| e.dig("function", "name") == "Agent" }
    assert_equal "nexus.graph.delegate_task", entry["canonical"]
    assert_equal %w[prompt model lifetime wake run_in_background tools], entry.dig("function", "parameters", "properties").keys
    description = entry.dig("function", "description")
    assert_includes description, "`run_in_background: false` means your next round WAITS for the task"
    refute_includes description, "`wait: true` means your next round WAITS", "the re-cut paragraph stands in place of the kernel's"
    assert_includes description, "Delegate from what the person told you, in your FIRST message",
      "the worked example stays: the variant that dropped it did not clear"
    refute_includes description, "{{"
    task = DeclaredSet.function_definitions.find { |e| e.dig("function", "name") == "delegate_task" }
    assert_includes task.dig("function", "description"), "`wait: true` means your next round WAITS",
      "the kernel's own task text is untouched: the candidate is a variant beside it"
    assert_nil Nexus::ToolDeclarations.refusal(DeclaredSet.function_definitions(style: "nexus", candidate: agent))
    wired = DeclaredSet.symbolized_definitions(style: "nexus", candidate: agent).find { |e| e.dig(:function, :name) == "Agent" }
    assert_equal %i[function type], wired.keys.sort, "no alias fact reaches a provider"
    assert_equal DeclaredSet.names, DeclaredSet.names(style: "nexus", candidate: hint), "a hint changes no name"

    baseline = DeclaredSet.instructions
    hinted = DeclaredSet.instructions(candidate: hint)
    assert_includes hinted, hint.payload
    refute_includes baseline, hint.payload
    assert_operator hinted.index(hint.payload), :>, hinted.index("You can call several tools in one message."),
      "the stable guideline precedes a row's variable hints"
    assert_operator hinted.index(hint.payload), :>, hinted.index("bash"), "after the tool lines"
    assert_equal baseline, DeclaredSet.instructions(candidate: agent), "an entry changes no instruction"

    samples = [
      { "objective" => "T2", "model" => "moonshotai/kimi-k3", "style" => "nexus", "sample" => 1, "pass" => true, "called" => { "delegate_task" => 1 } },
      { "objective" => "T2", "model" => "moonshotai/kimi-k3", "style" => "nexus", "candidate" => hint.key, "sample" => 1, "pass" => false,
        "called" => { "bash" => 2 } },
    ]
    Dir.mktmpdir("bench") do |dir|
      E2E::TaskBench::Report.write_offline(samples, dir: dir)
      assert_equal %w[results-task-moonshotai-kimi-k3-nexus-kimi-k3-test-hint.md results-task-moonshotai-kimi-k3-nexus.md],
        Dir.children(dir).grep(/\Aresults-/).sort, "one table per (model × style × candidate)"
      table = File.read(File.join(dir, "results-task-moonshotai-kimi-k3-nexus-kimi-k3-test-hint.md"), encoding: Encoding::UTF_8)
      assert_includes table, "style `nexus`, candidate `kimi-k3/test-hint`"
      assert_includes table, "| T2 background-suite | 0/1 | 1 |"
      refute_includes table, "\"candidate\"", "the key is the table's, not a property column"
    end
  end

  # THE SWEEP'S STYLE ROW ON THE LIVE READOUT (`E2E_LIVE_ADAPTATIONS`): a run under the `sweep` row
  # is keyed by its `adaptations` beside the baseline's, so neither replaces the other; a baseline
  # row carries none, as every row before the knob did.
  def test_the_live_readout_keys_a_sweep_row_beside_the_baseline
    baseline = [{ "objective" => "mail", "model" => "x/y", "run" => 1, "pass" => true }]
    sweep = [{ "objective" => "mail", "model" => "x/y", "run" => 1, "pass" => false, "adaptations" => "sweep:claude" }]
    merged = E2E::TaskBench::Report.merge_live(baseline, sweep)
    assert_equal [[nil, true], ["sweep:claude", false]], merged.map { |r| r.values_at("adaptations", "pass") }
    assert_equal %w[claude], E2E::AdaptationRows.words("claude")
    assert_equal %w[nexus claude], E2E::AdaptationRows.words("nexus+claude")
    assert_raises(ArgumentError) { E2E::AdaptationRows.words("gemini") }
    row = YAML.safe_load(YAML.dump(E2E::AdaptationRows.word_row("sweep", %w[claude])))
    assert_equal({ "row" => "sweep", "models" => [], "tool_style" => ["claude"] },
      row.slice("row", "models", "tool_style"))
    Dir.mktmpdir("adaptations") do |dir|
      File.write(File.join(dir, "sweep.yml"), YAML.dump(row))
      loaded = CybrosAgent::ModelAdaptations.load(extra: [dir]).row("sweep")
      assert_equal ["claude"], loaded.tool_style.to_a
      assert_predicate loaded, :local?
      assert_equal [[], nil, []], [loaded.tool_descriptions, loaded.summarizer_prompt, loaded.lead_hints], "a word row carries no text"
    end
  end

  # THE OUTPUT CAP IS PER MODEL on this lane too: a thinking model on the
  # stronger tier spends a flat 4096 before its first call, and the record
  # then reads as "no call" with nothing to say why. The cap is the one
  # table both benches read (`E2E::OutputCaps`), and every sample carries
  # the cap it ran under beside the provider's finish.
  def test_the_output_cap_is_the_one_table_both_benches_read
    assert_equal 16_384, E2E::OutputCaps.for("z-ai/glm-5.3")
    assert_equal 16_384, E2E::OutputCaps.for("moonshotai/kimi-k3")
    assert_equal 4096, E2E::OutputCaps.for("z-ai/glm-5.3-flash")
    assert_equal 4096, E2E::OutputCaps.for("x/y")
    # The direct frontier lanes (wire ids): the vendors' own floor for
    # reasoning plus output is 25,000 (OpenAI's reasoning guide), and Opus
    # 5.5's adaptive thinking counts against max_tokens.
    # Grok 4.7 reasons always, and its reasoning counts against
    # max_output_tokens (xAI's Responses reference).
    %w[claude-opus-5-5 gpt-6.1-sol gpt-6-luna grok-4.7].each do |model|
      assert_equal 32_768, E2E::OutputCaps.for(model), model
    end
    assert_equal 2048, E2E::OutputCaps.for("z-ai/glm-5.3", { "E2E_BENCH_MAX_OUTPUT_TOKENS" => "2048" })
    assert_equal 16_384, E2E::OutputCaps.for("z-ai/glm-5.3", { "E2E_BENCH_MAX_OUTPUT_TOKENS" => "" })
  end

  # Manual targets follow the configured floor; each ref resolves to its own provider.
  def test_the_default_models_are_the_evals_floor_each_on_its_own_lane
    assert_equal E2E::Evals::Bench.read.tiers.fetch("floor"), E2E::TaskBench::WEAK_MODELS
    E2E::TaskBench::WEAK_MODELS.each do |ref|
      assert_equal ref.split("/", 2).first, E2E::ProviderLanes.route(ref).lane.provider_id
    end
  end

  # A SAMPLE ON THE DIRECT FLOOR, OVER ITS REAL WIRE (a recording transport, no socket): the
  # request is the lane's, and an empty message under an exhausted cap is read as the cap — the
  # Responses wire's `incomplete` beside its typed reason and the gem's reading — never as a
  # choice, and never confused with a filtered answer, which says `incomplete` too.
  def test_a_sample_on_the_direct_floor_records_the_typed_finish_beside_the_cap
    route = E2E::ProviderLanes.route("deepseek/deepseek-flash")
    incomplete = ->(reason) do
      { "id" => "resp_1", "object" => "response", "status" => "incomplete", "output" => [],
        "usage" => { "input_tokens" => 9_000, "output_tokens" => 4_096 }, "incomplete_details" => { "reason" => reason } }
    end
    wire = RecordingAdapter.new(incomplete.("max_output_tokens"), incomplete.("content_filter"))
    client = E2E::ManualClient.for(route, env: { "DEEPSEEK_API_KEY" => "direct-placeholder" }, adapter: wire)
    sample = ->(index) do
      E2E::TaskBench::Sample.call(client: client, route: route, style: "nexus", candidate: nil,
        objective: Objectives.find("G0"), index: index, declared: declared)
    end

    cut = sample.(1)
    assert_equal "https://api.deepseek.com/responses", wire.requests.fetch(0).fetch(:url)
    assert_equal "deepseek-flash", JSON.parse(wire.requests.fetch(0).fetch(:body)).fetch("model")
    refute cut["pass"]
    assert_equal ["deepseek/deepseek-flash", E2E::OutputCaps.for("deepseek-flash")], cut.values_at("model", "max_output_tokens")
    assert_equal %w[incomplete max_output_tokens output_budget_exhausted], cut.values_at("finish", "finish_detail", "finish_quality")
    assert_equal({ "input_tokens" => 9_000, "output_tokens" => 4_096 }, cut["usage"])

    filtered = sample.(2)
    assert_equal %w[incomplete content_filter refused], filtered.values_at("finish", "finish_detail", "finish_quality")
  end

  # AN OPUS SAMPLE CARRIES THE KERNEL'S TWO CACHE MARKERS, OVER ITS REAL WIRE: the system block's,
  # which caches rho's whole declared set with it, and the tail on the ask.
  def test_an_opus_sample_carries_the_kernels_two_cache_markers
    route = E2E::ProviderLanes.route("anthropic/claude-opus-5-5")
    wire = RecordingAdapter.new({ "id" => "msg_1", "type" => "message", "role" => "assistant", "model" => "claude-opus-5-5",
      "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn",
      "usage" => { "input_tokens" => 4, "cache_creation_input_tokens" => 13_970, "output_tokens" => 153 } })
    client = E2E::ManualClient.for(route, env: { "ANTHROPIC_API_KEY" => "anthropic-placeholder" }, adapter: wire)
    sample = E2E::TaskBench::Sample.call(client: client, route: route, style: "nexus", candidate: nil,
      objective: Objectives.find("G0"), index: 1, declared: declared)

    body = JSON.parse(wire.requests.fetch(0).fetch(:body))
    assert_equal({ "type" => "ephemeral" }, body.fetch("system").last["cache_control"], "the stable marker")
    assert_equal({ "type" => "ephemeral" }, body.fetch("messages").last.fetch("content").last["cache_control"], "the tail")
    assert_equal 2, JSON.generate(body).scan("\"cache_control\"").size, "two breakpoints, no more"
    assert_equal({ "input_tokens" => 13_974, "output_tokens" => 153, "cache_creation_tokens" => 13_970 }, sample["usage"])
  end

  # A RESET THE PRODUCT WOULD HAVE RETRIED IS RETRIED, OVER THE REAL WIRE: the socket's reset
  # reaches the sample as the gem's lost connection, the kernel's list asks again, and the answer
  # is scored with the retry kept beside it; a sample that met none carries no `retries`.
  def test_a_reset_call_is_retried_and_the_sample_keeps_the_retry
    route = E2E::ProviderLanes.route("deepseek/deepseek-flash")
    answer = { "id" => "resp_1", "object" => "response", "status" => "completed", "output" => [],
               "usage" => { "input_tokens" => 9_000, "output_tokens" => 12 } }
    wire = ResettingAdapter.new([Errno::ECONNRESET.new], answer, answer)
    client = E2E::ManualClient.for(route, env: { "DEEPSEEK_API_KEY" => "direct-placeholder" }, adapter: wire)
    pauses = []
    sample = ->(index) do
      E2E::TaskBench::Sample.call(client: client, route: route, style: "nexus", candidate: nil,
        objective: Objectives.find("G0"), index: index, declared: declared, pause: ->(seconds) { pauses << seconds })
    end

    retried = sample.(1)
    assert_equal 2, wire.requests.length, "the reset call and the one that answered"
    assert_equal [{ "error" => "SimpleInference::ConnectionError: Connection reset by peer", "pause_seconds" => 10 }],
      retried["retries"]
    assert_equal [10], pauses
    assert_equal ["completed", { "input_tokens" => 9_000, "output_tokens" => 12 }], retried.values_at("finish", "usage")
    refute retried.key?("error"), retried.inspect

    refute sample.(2).key?("retries"), "a call that answered first has no retry to keep"
  end

  def test_gate_zero_counts_calls_in_one_message
    scored = Objectives::GATE_0.score([call("read", path: "lib/alpha.rb"), call("read", path: "lib/bravo.rb")], declared: declared)
    assert scored["pass"]
    assert_equal({ "read" => 2 }, scored["called"])
    refute Objectives::GATE_0.score([call("read", path: "lib/alpha.rb")], declared: declared)["pass"]
  end

  # THE DEFAULT IS THE BACKGROUND: a `task` call for the suite WITHOUT `wait: true` is in the
  # background; `wait: true` is the one spelling that waits, and `wait: false` spells the default.
  def test_the_background_suite_wants_one_background_task_and_a_direct_lint_call
    good = [call("delegate_task", prompt: "Run bin/rails test and answer the failing tests as file:line."),
            call("bash", command: "bin/rubocop app")]
    assert Objectives::OBJECTIVE_2.score(good, declared: declared)["pass"]
    spelled = [call("delegate_task", prompt: "Run bin/rails test", wait: false), call("bash", command: "bin/rubocop app")]
    assert Objectives::OBJECTIVE_2.score(spelled, declared: declared)["suite_in_background"]

    waited = Objectives::OBJECTIVE_2.score([call("delegate_task", prompt: "Run bin/rails test", wait: true), call("bash", command: "bin/rubocop app")], declared: declared)
    refute waited["suite_in_background"], "wait: true is the foreground case now"

    process = Objectives::OBJECTIVE_2.score(good + [call("start_process", command: "bin/rails test")], declared: declared)
    refute process["no_start_process"]

    twice = Objectives::OBJECTIVE_2.score(good + [call("delegate_task", prompt: "Run the test suite again")], declared: declared)
    refute twice["one_task_for_the_suite"]

    no_lint = Objectives::OBJECTIVE_2.score(good.first(1), declared: declared)
    refute no_lint["lint_direct"]
  end

  # T2 UNDER A STYLE is scored through the kernel's own mapper: `Agent` without `run_in_background:
  # false` is in the background (the inverted default), with `false` it waits; `spawn_agent` is a
  # SPAWN, so the task objective sees no task in it — the codex row's task cell is the plain `task`.
  # The tally keeps the spelling the model used; a spelling the style did not declare is not a task.
  def test_the_background_suite_is_scored_on_the_resolved_call_under_each_style
    lint = call("bash", command: "bin/rubocop app")
    agent = Objectives::OBJECTIVE_2.score([call("Agent", prompt: "Run bin/rails test"), lint], declared: declared("claude"))
    assert agent["pass"], agent.inspect
    assert_equal({ "Agent" => 1, "bash" => 1 }, agent["called"])
    explicit = Objectives::OBJECTIVE_2.score([call("Agent", prompt: "Run bin/rails test", run_in_background: true), lint], declared: declared("claude"))
    assert explicit["suite_in_background"]
    waited = Objectives::OBJECTIVE_2.score([call("Agent", prompt: "Run bin/rails test", run_in_background: false), lint], declared: declared("claude"))
    refute waited["suite_in_background"], "run_in_background: false maps to wait: true"

    spawned = Objectives::OBJECTIVE_2.score([call("spawn_agent", prompt: "Run bin/rails test", wait: true), lint], declared: declared("codex"))
    refute spawned["suite_in_background"], "RE-LABELLED (D-4): spawn_agent resolves to spawn, which is no task"
    plain = Objectives::OBJECTIVE_2.score([call("delegate_task", prompt: "Run bin/rails test"), lint], declared: declared("codex"))
    assert plain["suite_in_background"], "under codex the task cell is the plain task"

    undeclared = Objectives::OBJECTIVE_2.score([call("Agent", prompt: "Run bin/rails test"), lint], declared: declared)
    refute undeclared["suite_in_background"], "Agent is not a task under the nexus style"
    plain = Objectives::OBJECTIVE_2.score([call("delegate_task", prompt: "Run bin/rails test"), lint], declared: declared("nexus+claude"))
    assert plain["suite_in_background"], "two presets on: both spellings resolve"
  end

  # THE SP ROWS: the `spawn`/`send`/`status`/ `cancel` texts are NEW bytes, measured here and never
  # tuned. Each row passes the message it describes and fails the near-misses it names; the label
  # and the public id both ride the cells.
  def test_sp0_wants_one_subagent_spawn_with_no_agent_and_no_task
    scored = Objectives::SP0.score([call("spawn", prompt: "Run bin/rails test and fix what fails.")], declared: declared)
    assert scored["pass"], scored.inspect
    assert_equal({ "spawn" => 1 }, scored["called"])
    refute Objectives::SP0.score([call("spawn", prompt: "Run the suite", agent: "@lark")], declared: declared)["no_agent"]
    refute Objectives::SP0.score([call("delegate_task", prompt: "Run the suite")], declared: declared)["spawned"]
    twice = Objectives::SP0.score([call("spawn", prompt: "Run the suite"), call("spawn", prompt: "Fix it")], declared: declared)
    refute twice["one_spawn"]
    both = Objectives::SP0.score([call("spawn", prompt: "Run the suite"), call("delegate_task", prompt: "Run the suite")], declared: declared)
    refute both["no_task"]
    refute Objectives::SP0.score([call("Agent", prompt: "Run the suite")], declared: declared("claude"))["spawned"], "Agent is a task"
  end

  def test_sp1_wants_the_peer_named_in_agent_by_handle
    good = Objectives::SP1.score([call("spawn", prompt: "Review lib/auth/session.rb", agent: "@lark")], declared: declared)
    assert good["pass"], good.inspect
    assert Objectives::SP1.score([call("spawn", prompt: "Review it", agent: "lark")], declared: declared)["agent_names_the_peer"], "the bare handle resolves too"
    refute Objectives::SP1.score([call("spawn", prompt: "Review it")], declared: declared)["agent_names_the_peer"], "a subagent is not the peer"
    refute Objectives::SP1.score([call("spawn", prompt: "Review it", agent: "@quill")], declared: declared)["agent_names_the_peer"], "the wrong peer"
    refute Objectives::SP1.score([call("spawn", prompt: "Review it", to: "@lark")], declared: declared)["agent_names_the_peer"],
      "`to` is a conversation, never the peer (r6)"
    refute Objectives::SP1.score([call("delegate_task", prompt: "Review lib/auth/session.rb")], declared: declared)["spawned"]
  end

  def test_sp2_wants_a_steered_send_to_the_label
    good = Objectives::SP2.score([call("send", to: "migrator", message: "Stop: edit lib/config/loader.rb, not legacy.rb.", steer: true)], declared: declared)
    assert good["pass"], good.inspect
    queued = Objectives::SP2.score([call("send", to: "migrator", message: "Wrong file.")], declared: declared)
    assert queued["sent"]
    refute queued["steered"], "a queued send lands after the damage"
    wrong = Objectives::SP2.score([call("send", to: "loader", message: "Wrong file.", steer: true)], declared: declared)
    refute wrong["to_is_the_label"]
    canceled = Objectives::SP2.score([call("cancel", to: "migrator")], declared: declared)
    refute canceled["sent"]
    refute canceled["no_cancel"], "cancel throws the work away; the text asked for a correction"
    refute Objectives::SP2.score([call("spawn", prompt: "Move the loader, the right file this time")], declared: declared)["sent"]
  end

  # SP3 IS THE TASK-VS-SPAWN LINE: two cells, one each side.
  def test_sp3_inference_request_review_is_a_task_and_a_persistent_reviewer_is_a_spawn
    once = Objectives::SP3A.score([call("delegate_task", prompt: "Review patch.diff; findings as file:line.")], declared: declared)
    assert once["pass"], once.inspect
    refute Objectives::SP3A.score([call("spawn", prompt: "Review patch.diff")], declared: declared)["task_not_spawn"]
    refute Objectives::SP3A.score([call("spawn_agent", prompt: "Review patch.diff")], declared: declared("codex"))["task_not_spawn"],
      "RE-LABELLED (D-4): the codex spawn_agent resolves to spawn"
    refute Objectives::SP3A.score([call("read", path: "patch.diff")], declared: declared)["delegated"]

    kept = Objectives::SP3B.score([call("spawn", prompt: "You are the reviewer for this branch. Review patch.diff first.")], declared: declared)
    assert kept["pass"], kept.inspect
    refute Objectives::SP3B.score([call("delegate_task", prompt: "Review patch.diff")], declared: declared)["spawn_not_task"]
    refute Objectives::SP3B.score([call("read", path: "patch.diff")], declared: declared)["delegated"]
  end

  def test_sp4_wants_no_status_call_beside_the_spawn_that_just_started
    good = Objectives::SP4.score([call("spawn", prompt: "Run bin/rails test"), call("bash", command: "ls lib | wc -l")], declared: declared)
    assert good["pass"], good.inspect
    assert good["worked_meanwhile"]
    polled = Objectives::SP4.score([call("spawn", prompt: "Run bin/rails test"), call("status", to: "suite")], declared: declared)
    refute polled["no_status"]
    refute polled["pass"]
    alone = Objectives::SP4.score([call("spawn", prompt: "Run bin/rails test")], declared: declared)
    assert alone["pass"], "the count may come in the next message"
    refute alone["worked_meanwhile"]
    refute Objectives::SP4.score([call("delegate_task", prompt: "Run bin/rails test")], declared: declared)["spawned"]
  end

  # A `status` call beside a task-result status attribute must address the conversation. Using the
  # task key or attribute value is a separate recorded confusion.
  def test_sp5_reads_whether_the_status_tool_was_confused_with_the_attribute
    id = Objectives::SP5_CONVERSATION
    good = Objectives::SP5.score([call("status", to: id)], declared: declared)
    assert good["pass"], good.inspect
    refute good["confused_with_the_attribute"]
    key = Objectives::SP5.score([call("status", to: "r2t1")], declared: declared)
    assert key["status_called"]
    refute key["to_is_the_conversation"]
    assert key["confused_with_the_attribute"], "the task key is the attribute's neighbour, not an address"
    word = Objectives::SP5.score([call("status", to: "canceled")], declared: declared)
    assert word["confused_with_the_attribute"]
    refute word["pass"]
    canceled = Objectives::SP5.score([call("cancel", to: id)], declared: declared)
    refute canceled["no_cancel"], "the reply was already canceled; the person asked a question"
    none = Objectives::SP5.score([], declared: declared)
    refute none["status_called"], "answered from the attribute alone"
    assert_includes Objectives::SP5.text, "<task_result task=\"r2t1\" status=\"canceled\" conversation=\"#{id}\">"
    assert_includes Objectives::SP5.text, "</task_result>\n\n", "the wire merge's shape: the close line, a blank line, the person's word"
  end

  # THE TOOL-TEXT ROWS (TT1–TT5): five model-facing shapes written as designed and left to the paid
  # window, each scored on the call's own ARGUMENTS — `ask`'s `options`, `model` on spawn/send, the
  # runner's `find` against `bash find`, pi's `edits[]` array, `deliver_in` against `deliver_at`.
  # They resolve by id the way the probe's `E2E_TASK_OBJECTIVES` selects them, and every tool they
  # measure is in the set a rho turn declares.
  def test_the_tool_text_rows_resolve_by_id_the_way_the_probe_selects_them
    ids = %w[TT1 TT2 TT3 TT4 TT5]
    assert_equal ids, "TT1,TT2,TT3,TT4,TT5".split(",").map { |id| Objectives.find(id) }.map(&:id)
    assert_equal ids, Objectives.ids & ids, "registered in ALL, in order"
    assert_equal Objectives::ALL.length, Objectives.ids.uniq.length, "no id twice"
    assert_raises(ArgumentError) { Objectives.find("TT9") }
    ids.each do |id|
      objective = Objectives.find(id)
      assert_equal 3, objective.samples
      refute_match(/\b(ask|spawn|send|find|edit|deliver_in|deliver_at|options|multi|model|pattern)\b/i, objective.text.gsub(/`[^`]*`/, ""),
        "#{id}'s text names neither the tool nor its parameter outside a code span")
    end
    %w[ask spawn send find edit write bash].each { |name| assert_includes DeclaredSet.names, name }
    assert_includes DeclaredSet.function_definitions.find { |e| e.dig("function", "name") == "delegate_task" }
      .dig("function", "parameters", "properties").keys, "model", "TT2 accepts explicit model selection on task branches"
  end

  # TT1: the alternatives ride `options` as data; an ask whose prompt lists
  # them in its words is `prompt_only`; `multi: true` is the wrong shape for
  # one pick; a shape the kernel refuses by sentence (`Asks::Run#refusal_for`:
  # a stray key, an empty prompt, non-string options, a non-boolean multi) is
  # `refused_shape`, never data; the claude alias is flat, so `AskUserQuestion`
  # resolves alike.
  def test_tt1_wants_the_alternatives_as_ask_options_not_in_the_prompt
    good = Objectives::TT1.score([call("ask", prompt: "Which target?", options: %w[staging canary production])], declared: declared)
    assert good["pass"], good.inspect
    assert good["ask_called"]
    assert good["options_as_data"]
    assert_equal 3, good["options_count"]
    refute good["prompt_only"]
    assert good["single_choice"]
    prompt = Objectives::TT1.score([call("ask", prompt: "Deploy to staging, canary or production?")], declared: declared)
    assert prompt["ask_called"]
    refute prompt["options_as_data"]
    assert prompt["prompt_only"], "the alternatives in the prompt's words are not data"
    assert_equal 0, prompt["options_count"]
    refute prompt["pass"]
    multi = Objectives::TT1.score([call("ask", prompt: "Which?", options: %w[staging canary production], multi: true)], declared: declared)
    refute multi["single_choice"]
    refute multi["pass"], "one target, never several"
    other = Objectives::TT1.score([call("ask", prompt: "Deploy?", options: %w[yes no])], declared: declared)
    refute other["options_as_data"], "options that are not the alternatives"
    assert_equal 2, other["options_count"]
    refute other["pass"]
    twice = Objectives::TT1.score([call("ask", prompt: "Which?", options: %w[staging canary production]),
                                   call("ask", prompt: "Sure?", options: %w[yes no])], declared: declared)
    refute twice["pass"], "one question"
    claude = Objectives::TT1.score([call("AskUserQuestion", prompt: "Which target?", options: %w[staging production])], declared: declared("claude"))
    assert claude["pass"], claude.inspect
    assert_equal({ "AskUserQuestion" => 1 }, claude["called"])
    none = Objectives::TT1.score([call("bash", command: "bin/deploy staging")], declared: declared)
    refute none["ask_called"]
    refute none["pass"]
    refute good["refused_shape"]
    objects = Objectives::TT1.score([call("ask", prompt: "Which?", options: [{ label: "staging" }, { label: "canary" }])], declared: declared)
    assert objects["refused_shape"], "the kernel takes strings: claude-code's {label} objects are refused options_invalid"
    refute objects["options_as_data"], "a refused shape is never data"
    refute objects["pass"]
    stray = Objectives::TT1.score([call("ask", prompt: "Which?", options: %w[staging canary], questions: [])], declared: declared)
    assert stray["refused_shape"], "a key beyond prompt/options/multi is refused by name"
    refute stray["pass"]
    assert Objectives::TT1.score([call("ask", prompt: "Which?", options: %w[staging canary], multi: "no")], declared: declared)["refused_shape"],
      "multi is a boolean"
    ["", "   ", nil].each do |prompt|
      blank = Objectives::TT1.score([call("ask", prompt: prompt, options: %w[staging canary production])], declared: declared)
      assert blank["refused_shape"], "the kernel refuses an empty prompt (#{prompt.inspect}): prompt is empty."
      refute blank["options_as_data"], "a refused shape is never data"
      refute blank["pass"]
    end
    refute Objectives::TT1.score([call("ask", options: %w[staging canary production])], declared: declared)["pass"], "no prompt at all"
  end

  # TT2: the authored delegation names the requested catalog id. Bare
  # delegation or another id are near-misses; execution identity belongs
  # to the runtime acceptance tests, not this structural scorer.
  def test_tt2_wants_the_named_model_on_the_delegation
    id = Objectives::TT2_REVIEWER
    good = Objectives::TT2.score([call("spawn", prompt: "Review patch.diff for correctness.", model: id)], declared: declared)
    assert good["pass"], good.inspect
    assert_equal "spawn", good["tool"]
    assert good["model_named"]
    assert_equal id, good["model_value"]
    refute good["model_on_task"]
    sent = Objectives::TT2.score([call("send", to: "reviewer", message: "Review patch.diff", model: id)], declared: declared)
    assert sent["pass"], sent.inspect
    assert_equal "send", sent["tool"]
    codex = Objectives::TT2.score([call("spawn_agent", prompt: "Review patch.diff", model: id)], declared: declared("codex"))
    assert codex["pass"], codex.inspect
    assert_equal "spawn", codex["tool"], "scored as the kernel resolves it"
    bare = Objectives::TT2.score([call("spawn", prompt: "Review patch.diff")], declared: declared)
    assert bare["delegated"]
    refute bare["model_named"]
    assert_nil bare["model_value"]
    refute bare["pass"]
    wrong = Objectives::TT2.score([call("spawn", prompt: "Review patch.diff", model: "fixture/text")], declared: declared)
    assert wrong["model_named"]
    assert_equal "fixture/text", wrong["model_value"]
    refute wrong["model_is_the_id"]
    refute wrong["pass"]
    task = Objectives::TT2.score([call("delegate_task", prompt: "Review patch.diff", model: id)], declared: declared)
    assert task["model_on_task"]
    assert task["model_named"]
    assert task["pass"], task.inspect
    aliased = Objectives::TT2.score([call("Agent", prompt: "Review patch.diff", model: id)], declared: declared("claude"))
    assert aliased["pass"], aliased.inspect
    assert_equal "delegate_task", aliased["tool"]
    refute Objectives::TT2.score([call("read", path: "patch.diff")], declared: declared)["delegated"]
  end

  # TT3: the runner's `find`, not `bash` running find/fd/ls -R/a glob.
  def test_tt3_wants_the_runners_find_not_a_bash_search
    good = Objectives::TT3.score([call("find", pattern: "**/*_job.rb", path: "lib")], declared: declared)
    assert good["pass"], good.inspect
    assert good["find_called"]
    refute good["bash_find"]
    assert_equal "**/*_job.rb", good["pattern"]
    assert good["pattern_names_the_suffix"]
    bash = Objectives::TT3.score([call("bash", command: "find lib -name '*_job.rb'")], declared: declared)
    refute bash["find_called"]
    assert bash["bash_find"]
    refute bash["pass"]
    assert Objectives::TT3.score([call("bash", command: "ls -R lib | grep _job.rb")], declared: declared)["bash_find"]
    assert Objectives::TT3.score([call("bash", command: "fd _job.rb lib")], declared: declared)["bash_find"]
    assert Objectives::TT3.score([call("bash", command: "ls lib/**/*_job.rb")], declared: declared)["bash_find"]
    both = Objectives::TT3.score([call("find", pattern: "*_job.rb", path: "lib"), call("bash", command: "find lib -name '*_job.rb'")], declared: declared)
    assert both["find_called"]
    refute both["pass"], "the bash search beside it is the over-reach"
    grep = Objectives::TT3.score([call("grep", pattern: "_job.rb", path: "lib")], declared: declared)
    refute grep["find_called"]
    refute grep["bash_find"]
    refute grep["pass"]
    assert_nil grep["pattern"]
    refute Objectives::TT3.score([call("bash", command: "bin/rails test")], declared: declared)["bash_find"], "a bash that searches nothing"
  end

  # TT4: ONE `edit` whose `edits[]` carries the changes as oldText/newText
  # pairs; three single-entry calls, a `write` of the whole file, or
  # claude-code's `old_string` pair (the schema refuses it) are the near-misses.
  def test_tt4_wants_one_edit_call_carrying_the_three_changes
    pairs = [{ oldText: "TIMEOUT = 30", newText: "TIMEOUT = 60" },
             { oldText: "RETRIES = 3", newText: "RETRIES = 5" },
             { oldText: "LOG_LEVEL = :info", newText: "LOG_LEVEL = :warn" }]
    good = Objectives::TT4.score([call("edit", path: "config/settings.rb", edits: pairs)], declared: declared)
    assert good["pass"], good.inspect
    assert_equal 1, good["edit_calls"]
    assert_equal 3, good["edits_in_first"]
    assert good["multi_edit_shape"]
    assert good["covers_the_three"]
    refute good["write_instead"]
    refute good["refused_shape"]
    two = Objectives::TT4.score([call("edit", path: "config/settings.rb", edits: pairs.first(2))], declared: declared)
    assert two["multi_edit_shape"], "two entries is the multi shape"
    refute two["covers_the_three"]
    three = Objectives::TT4.score(pairs.map { |pair| call("edit", path: "config/settings.rb", edits: [pair]) }, declared: declared)
    assert_equal 3, three["edit_calls"]
    assert_equal 1, three["edits_in_first"]
    refute three["multi_edit_shape"]
    refute three["pass"]
    write = Objectives::TT4.score([call("write", path: "config/settings.rb", content: "module Settings\n  TIMEOUT = 60\nend\n")], declared: declared)
    assert write["write_instead"]
    assert_equal 0, write["edit_calls"]
    refute write["pass"]
    both = Objectives::TT4.score([call("edit", path: "config/settings.rb", edits: pairs), call("write", path: "config/settings.rb", content: "x")], declared: declared)
    refute both["pass"]
    foreign = Objectives::TT4.score([call("edit", path: "config/settings.rb", old_string: "TIMEOUT = 30", new_string: "TIMEOUT = 60")], declared: declared)
    assert foreign["refused_shape"], "claude-code's pair is not edits[]"
    assert_equal 0, foreign["edits_in_first"]
    refute foreign["multi_edit_shape"]
    refute foreign["pass"]
    halves = Objectives::TT4.score([call("edit", path: "config/settings.rb", edits: [{ oldText: "TIMEOUT = 30" }, { oldText: "RETRIES = 3", newText: "RETRIES = 5" }])], declared: declared)
    assert halves["refused_shape"], "an entry without newText"
    refute halves["pass"]
    # The runner's own schema (`InputSchema.refusal` over edit's validator) decides the column:
    # `path` is required, an empty `edits[]` is not refused there.
    pathless = Objectives::TT4.score([call("edit", edits: pairs)], declared: declared)
    assert pathless["refused_shape"], "an edit with no path is refused by the runner's schema"
    refute pathless["pass"], "a refused edit changed nothing"
    refute Objectives::TT4.score([call("edit", path: "config/settings.rb", edits: [])], declared: declared)["refused_shape"],
      "the schema takes an empty edits[]; it is simply not the multi shape"
    refute Objectives::TT4.score([call("read", path: "config/settings.rb")], declared: declared)["pass"]
  end

  # TT5: `send` carrying `deliver_in` (the delay the person gave) and not
  # `deliver_at`; the kernel's delay grammar is its own column, as is a
  # `sleep` in bash/start_process instead of the clock.
  def test_tt5_wants_deliver_in_on_the_send_and_no_deliver_at
    good = Objectives::TT5.score([call("send", to: "self", message: "Restart the staging worker.", deliver_in: "20m")], declared: declared)
    assert good["pass"], good.inspect
    assert good["send_called"]
    assert good["deliver_in"]
    refute good["deliver_at"]
    assert_equal "20m", good["value"]
    assert good["kernel_shape"]
    refute good["sleep_instead"]
    at = Objectives::TT5.score([call("send", to: "self", message: "Restart it.", deliver_at: "2026-09-16T09:20:00Z")], declared: declared)
    assert at["send_called"]
    assert at["deliver_at"]
    refute at["deliver_in"]
    assert_nil at["value"]
    refute at["pass"], "the person gave a delay, not a time"
    both = Objectives::TT5.score([call("send", to: "self", message: "Restart it.", deliver_in: "20m", deliver_at: "2026-09-16T09:20:00Z")], declared: declared)
    refute both["pass"], "both at once: the kernel refuses it"
    seconds = Objectives::TT5.score([call("send", to: "self", message: "Restart it.", deliver_in: 1200)], declared: declared)
    assert seconds["deliver_in"]
    assert seconds["pass"], "the reach is the property"
    assert_equal 1200, seconds["value"]
    refute seconds["kernel_shape"], "a bare number is refused deliver_in_invalid"
    now = Objectives::TT5.score([call("send", to: "self", message: "Restart the staging worker.")], declared: declared)
    assert now["send_called"]
    refute now["deliver_in"]
    refute now["pass"]
    codex = Objectives::TT5.score([call("send_message", target: "self", message: "Restart it.", deliver_in: "20m")], declared: declared("codex"))
    assert codex["pass"], codex.inspect
    slept = Objectives::TT5.score([call("start_process", command: "sleep 1200 && echo restart")], declared: declared)
    refute slept["send_called"]
    assert slept["sleep_instead"]
    refute slept["pass"]
    assert Objectives::TT5.score([call("bash", command: "sleep 1200")], declared: declared)["sleep_instead"]
  end

  def test_the_control_wants_greps_and_no_graph_verb
    greps = Objectives::CONFIGS.map { |file| call("grep", pattern: "debug", path: file) }
    assert Objectives::CONTROL.score(greps, declared: declared)["pass"]
    refute Objectives::CONTROL.score(greps + [call("delegate_task", prompt: "grep the configs")], declared: declared)["task_zero"]
    refute Objectives::CONTROL.score(greps + [call("Agent", prompt: "grep the configs")], declared: declared("claude"))["task_zero"]
    refute Objectives::CONTROL.score(greps.first(1), declared: declared)["two_calls_in_message"]
  end

  def test_the_readout_writes_one_table_per_model_and_style
    samples = [
      { "objective" => "T2", "model" => "x/y", "style" => "nexus", "sample" => 1, "pass" => true, "suite_in_background" => true,
        "lint_direct" => true, "one_task_for_the_suite" => true, "no_start_process" => true, "called" => { "delegate_task" => 1, "bash" => 1 } },
      { "objective" => "T2", "model" => "x/y", "style" => "nexus", "sample" => 2, "pass" => false, "suite_in_background" => false,
        "lint_direct" => true, "one_task_for_the_suite" => true, "no_start_process" => true, "called" => { "bash" => 2 } },
      { "objective" => "T2", "model" => "x/y", "style" => "claude", "sample" => 1, "pass" => true, "suite_in_background" => true,
        "lint_direct" => true, "one_task_for_the_suite" => true, "no_start_process" => true, "called" => { "Agent" => 1, "bash" => 1 } },
    ]
    Dir.mktmpdir("bench") do |dir|
      E2E::TaskBench::Report.write_offline(samples, dir: dir)
      assert_equal %w[results-task-x-y-claude.md results-task-x-y-nexus.md], Dir.children(dir).grep(/\Aresults-/).sort
      table = File.read(File.join(dir, "results-task-x-y-nexus.md"), encoding: Encoding::UTF_8)
      assert_includes table, "# task bench (offline) — model `x/y`, style `nexus`"
      assert_includes table, "| T2 background-suite | 1/2 | 2 | suite_in_background 1/2; lint_direct 2/2; " \
                             "one_task_for_the_suite 2/2; no_start_process 2/2 | delegate_task×1 bash×3 |"
      refute_includes table, "T1", "task alone is retired"
      claude = File.read(File.join(dir, "results-task-x-y-claude.md"), encoding: Encoding::UTF_8)
      assert_includes claude, "| T2 background-suite | 1/1 | 1 |"
      assert_includes claude, "Agent×1 bash×1"
      assert File.exist?(File.join(dir, "task_matrix.json"))

      runs = [{ "objective" => "mail", "model" => "x/y", "run" => 1, "pass" => true, "mailed" => true, "named" => true }]
      E2E::TaskBench::Report.write_live(runs, dir: dir)
      live = File.read(File.join(dir, "results-task-mail-x-y.md"), encoding: Encoding::UTF_8)
      assert_includes live, "| mail | 1 | PASS |"
      assert_includes live, "- mail: 1/1"
    end
  end

  # THE LIVE READOUT MERGES (Gate 3 F6): the sweep runs one paid matrix per
  # model, so a second `write_live` keeps the first model's rows, and a
  # re-run of one (objective, model, run) replaces the older row with the
  # newer; the per-model tables are regenerated from the union.
  def test_the_live_readout_merges_with_the_rows_on_disk_newer_winning
    first = [{ "objective" => "mail", "model" => "x/y", "run" => 1, "pass" => false, "mailed" => false },
             { "objective" => "fan", "model" => "x/y", "run" => 1, "pass" => true }]
    second = [{ "objective" => "mail", "model" => "x/y", "run" => 1, "pass" => true, "mailed" => true },
              { "objective" => "mail", "model" => "p/q", "run" => 1, "pass" => true, "mailed" => true }]
    Dir.mktmpdir("bench") do |dir|
      E2E::TaskBench::Report.write_live(first, dir: dir)
      E2E::TaskBench::Report.write_live(second, dir: dir)
      rows = JSON.parse(File.read(File.join(dir, "task_mail.json"), encoding: Encoding::UTF_8))
      assert_equal 3, rows.length, rows.inspect
      keyed = rows.to_h { |r| [r.values_at("objective", "model", "run"), r] }
      assert_equal({ "objective" => "mail", "model" => "x/y", "run" => 1, "pass" => true, "mailed" => true },
        keyed.fetch(["mail", "x/y", 1]), "the newer row replaces the older on the same key")
      assert keyed.fetch(["fan", "x/y", 1]).fetch("pass"), "the disjoint row from the first write survives"
      assert keyed.key?(["mail", "p/q", 1])
      x_y = File.read(File.join(dir, "results-task-mail-x-y.md"), encoding: Encoding::UTF_8)
      assert_includes x_y, "| mail | 1 | PASS |"
      assert_includes x_y, "- fan: 1/1"
      assert_includes x_y, "- mail: 1/1"
      p_q = File.read(File.join(dir, "results-task-mail-p-q.md"), encoding: Encoding::UTF_8)
      assert_includes p_q, "| mail | 1 | PASS |"
    end
  end
end
