require_relative "compose_bench_harness"
require_relative "recording_adapter"

# THE PROBE AND THE READOUT: a sample runs the first call, the kernel-shaped repair and both
# scorers over a scripted client, and over the real wire of the lane its ref names through a
# recording transport; the output cap, the style and each call's spend and finish ride every
# sample; the readout writes one table per cell and a partial run keeps the cells it did not run.
class ComposeBenchProbeHarnessTest < Minitest::Test
  include ComposeBenchHarness

  def test_the_captures_stay_with_local_artifacts_unless_the_env_names_another
    artifacts = File.expand_path("../artifacts/bench/captures", __dir__)
    assert_equal artifacts, E2E::ComposeBench::Report.captures_dir({})
    assert_equal artifacts, E2E::ComposeBench::Report.captures_dir({ "E2E_BENCH_CAPTURES_DIR" => "" })
    assert_equal "/scratch/bench/captures", E2E::ComposeBench::Report.captures_dir({ "E2E_BENCH_DIR" => "/scratch/bench" })
    assert_equal "/scratch/bench-strong/captures",
      E2E::ComposeBench::Report.captures_dir({ "E2E_BENCH_CAPTURES_DIR" => "/scratch/bench-strong/captures" })
  end

  def test_the_probe_scores_a_refusal_a_valid_script_and_a_control_without_a_model
    probe = E2E::ComposeBench::Probe.new(client: nil, route: route, row: shipped_row)
    scored = probe.send(:score, Objectives.find("O2"), { script: 'g.tool({ name: "read", input: {} });', params: {} })
    assert_equal "unknown_tool_name", scored["refusal"]
    assert_equal "tool_name", scored["loud"]
    refute scored["valid_first"]

    scored = probe.send(:score, Objectives.find("O2"), { script: CANONICAL.fetch("O2"), params: {} })
    assert scored["first_time_right"], scored.inspect
    assert_equal 3, scored.dig("graph", "edges").length

    scored = probe.send(:score, Objectives.find("O5"), { script: 'g.tool({ name: "read_file", input: { path: "app.yml" } });', params: {} })
    assert_equal ["over_reach"], scored["silent"]
    refute scored["compose_zero"]
  end

  # THE WHOLE SAMPLE PATH — first call, the kernel-shaped repair turn,
  # both scorers — over a scripted client, so the first paid call is not
  # the first time it runs.
  def test_a_sample_runs_the_first_call_the_repair_and_both_scorers_over_a_scripted_client
    client = ScriptedClient.new(
      ->(_request) { compose_call('g.tool({ name: "bash", command: "bin/rails test" });') },
      lambda do |request|
        repair = request.fetch(:input).last
        assert_equal "function_call_output", repair["type"]
        assert_includes repair["output"], "unknown option \"command\""
        compose_call(CANONICAL.fetch("O4"))
      end
    )
    probe = E2E::ComposeBench::Probe.new(client: client, route: route, row: shipped_row)
    sample = probe.sample(Objectives.find("O4"), 1)
    assert sample["reached"]
    refute sample["valid_first"]
    assert_equal "unknown_option", sample["loud"]
    assert_equal "valid", sample["repaired"]
    assert sample["right_after_repair"], sample.inspect
    assert_equal "O4", sample["objective"]

    control = E2E::ComposeBench::Probe.new(
      client: ScriptedClient.new(->(_r) { Answer.new([{ "id" => "r", "name" => "read_file", "arguments" => "{}" }], "", "tool_calls") }),
      route: route, row: shipped_row
    ).sample(Objectives.find("O5"), 1)
    assert control["compose_zero"]
    assert_equal({ "read_file" => 1 }, control["called"])
    assert_equal "tool_calls", control["finish"]

    # An EMPTY completion is recorded with the provider's finish fact, so
    # a no-call sample is never read as the model's choice by default.
    empty = E2E::ComposeBench::Probe.new(
      client: ScriptedClient.new(->(_r) { Answer.new([], "", "length") }), route: route, row: shipped_row
    ).sample(Objectives.find("O7"), 1)
    refute empty["reached"]
    assert_equal "length", empty["finish"]
    assert_includes E2E::ComposeBench::Report.markdown("R-WO", "x/y", [empty]),
      "no compose call ({}, finish length at the 4096-token cap)"
  end

  # A REPAIR CALL THAT RAISED keeps its error beside `no_second_call`: the word alone read a harness
  # fault on the second call as the model declining to call again, and the matrix's gate reads the
  # error. A second call that answers text and no compose is the model's, with no error to keep.
  def test_a_repair_call_that_raises_records_its_error_beside_no_second_call
    refused = ->(_request) { compose_call('g.tool({ name: "bash", command: "bin/rails test" });') }
    raised = E2E::ComposeBench::Probe.new(
      client: ScriptedClient.new(refused, ->(_request) { raise NoMethodError, "undefined method 'tool_calls' for nil" }),
      route: route, row: shipped_row
    ).sample(Objectives.find("O4"), 1)
    assert raised["reached"], raised.inspect
    assert_equal "no_second_call", raised["repaired"]
    assert raised["repaired_error"].to_s.start_with?("NoMethodError"), raised.inspect
    assert_equal false, raised["valid_after_repair"]

    declined = E2E::ComposeBench::Probe.new(
      client: ScriptedClient.new(refused, ->(_request) { Answer.new([], "I would rather not call it again.", "stop") }),
      route: route, row: shipped_row
    ).sample(Objectives.find("O4"), 1)
    assert_equal "no_second_call", declined["repaired"]
    refute declined.key?("repaired_error"), declined.inspect
    assert_equal false, declined["valid_after_repair"]
  end

  # A DRAW THE PRODUCT WOULD HAVE RETRIED IS RETRIED: a reset first call and a timed-out repair are
  # each asked again on the kernel's list, and the sample keeps every retry under its call's name —
  # `retries` for the first, `repaired_retries` for the repair — so a reading counts them. Resets
  # that spend the budget leave the draw unreached with its last error beside the two retries; a
  # provider's refusal is the draw's error at once, with no retry to record.
  def test_a_transient_failure_is_retried_and_every_retry_rides_the_sample
    pauses = []
    reset = ->(_request) { raise SimpleInference::ConnectionError, "Connection reset by peer" }
    timed_out = ->(_request) { raise SimpleInference::TimeoutError, "Net::ReadTimeout" }
    refused = ->(_request) { compose_call('g.tool({ name: "bash", command: "bin/rails test" });') }
    retried = E2E::ComposeBench::Probe.new(
      client: ScriptedClient.new(reset, refused, timed_out, ->(_request) { compose_call(CANONICAL.fetch("O4")) }),
      route: route, row: shipped_row, pause: ->(seconds) { pauses << seconds }
    ).sample(Objectives.find("O4"), 1)
    assert retried["reached"], retried.inspect
    assert_equal ["unknown_option", "valid", true], retried.values_at("loud", "repaired", "right_after_repair")
    assert_equal [{ "error" => "SimpleInference::ConnectionError: Connection reset by peer", "pause_seconds" => 10 }],
      retried["retries"]
    assert_equal [{ "error" => "SimpleInference::TimeoutError: Net::ReadTimeout", "pause_seconds" => 10 }],
      retried["repaired_retries"]
    assert_equal [10, 10], pauses, "each call's budget is its own"

    spent = E2E::ComposeBench::Probe.new(client: ScriptedClient.new(reset, reset, reset), route: route,
      row: shipped_row, pause: ->(_seconds) { }).sample(Objectives.find("O4"), 1)
    assert_equal [false, "SimpleInference::ConnectionError: Connection reset by peer"], spent.values_at("reached", "error")
    assert_equal 2, spent.fetch("retries").length

    response = SimpleInference::Response.new(status: 400, headers: {}, body: nil, raw_body: "")
    denied = E2E::ComposeBench::Probe.new(
      client: ScriptedClient.new(->(_request) { raise SimpleInference::HTTPError.new("HTTP 400", response: response) }),
      route: route, row: shipped_row, pause: ->(_seconds) { flunk "a refusal is not retried" }
    ).sample(Objectives.find("O4"), 1)
    assert_equal [false, "SimpleInference::HTTPError: HTTP 400"], denied.values_at("reached", "error")
    refute denied.key?("retries"), denied.inspect
  end

  # THE OUTPUT CAP IS PER MODEL: a thinking model spends a flat 4096
  # before its call (glm-5.3 read as "no compose, finish length" on six
  # of twelve O4 samples), so the table raises it for those, the env
  # overrides the table for one run, and every sample records the cap it
  # ran under beside the provider's finish, so an exhausted cap is read
  # as the cap and never as the model's choice.
  def test_the_output_cap_is_per_model_overridable_by_env_and_recorded_on_every_sample
    probe = E2E::ComposeBench::Probe
    assert_equal 16_384, probe.max_output_tokens("z-ai/glm-5.3")
    assert_equal 16_384, probe.max_output_tokens("moonshotai/kimi-k3"), "the third of the stronger tier"
    assert_equal 4096, probe.max_output_tokens("z-ai/glm-5.3-flash")
    assert_equal 4096, probe.max_output_tokens("x/y")
    assert_equal 2048, probe.max_output_tokens("z-ai/glm-5.3", { "E2E_BENCH_MAX_OUTPUT_TOKENS" => "2048" })
    assert_equal 16_384, probe.max_output_tokens("z-ai/glm-5.3", { "E2E_BENCH_MAX_OUTPUT_TOKENS" => "" })

    requests = []
    exhausted = probe.new(
      client: ScriptedClient.new(->(request) { requests << request; Answer.new([], "", "length") }),
      route: route("openrouter/z-ai/glm-5.3"), row: shipped_row
    ).sample(Objectives.find("O4"), 1)
    assert_equal 16_384, requests.fetch(0).fetch(:max_output_tokens), "the call carries the model's cap"
    assert_equal "z-ai/glm-5.3", requests.fetch(0).fetch(:model), "the wire names the lane's own id"
    assert_equal "openrouter/z-ai/glm-5.3", exhausted.fetch("model"), "the record names the ref the bench names"
    assert_equal [false, "length", 16_384], exhausted.values_at("reached", "finish", "max_output_tokens")
    assert_includes E2E::ComposeBench::Report.markdown("R-WO", "z-ai/glm-5.3", [exhausted]),
      "- O4#1: no compose call ({}, finish length at the 16384-token cap)"

    reached = probe.new(
      client: ScriptedClient.new(->(_r) { Answer.new(compose_call(CANONICAL.fetch("O4")).tool_calls, "", "tool_calls") }),
      route: route, row: shipped_row, max_output_tokens: 512
    ).sample(Objectives.find("O4"), 1)
    assert_equal [true, "tool_calls", 512], reached.values_at("reached", "finish", "max_output_tokens")
    assert_includes E2E::ComposeBench::Report.markdown("R-WO", "x/y", [reached]), "- O4#1: valid; exact"
  end

  # A PROBE UNDER A STYLE declares the style's entries beside the row's
  # compose — the alias's resolution facts stripped for the wire, as the
  # kernel strips them — and every sample records the style it ran under.
  def test_a_probe_under_a_style_declares_its_entries_stripped_for_the_wire_and_records_the_style
    requests = []
    probe = E2E::ComposeBench::Probe.new(
      client: ScriptedClient.new(->(request) { requests << request; compose_call(CANONICAL.fetch("O2")) }),
      route: route, row: shipped_row, style: Styles.find("claude")
    )
    sample = probe.sample(Objectives.find("O2"), 1)
    assert_equal "claude", sample["style"]
    assert sample["first_time_right"], sample.inspect
    tools = requests.fetch(0).fetch(:tools)
    assert_equal ["compose", *Tools::NAMES, "Agent", "AskUserQuestion"], tools.map { |tool| tool.dig(:function, :name) }
    assert_includes tools.first.dig(:function, :description), "nor\nAgent", "compose's text under the same set"
    assert_equal %i[function type], tools.last.keys.sort, "no `canonical`/`params` reaches a provider"
    assert_equal %i[prompt lifetime wake run_in_background tools], tools[-2].dig(:function, :parameters, :properties).keys

    plain = E2E::ComposeBench::Probe.new(client: nil, route: route, row: shipped_row)
    assert_equal "nexus", plain.sample(Objectives.find("O5"), 1).fetch("style"), "the default style is the baseline"
  end

  KEYS = { "DEEPSEEK_API_KEY" => "direct-placeholder", "OPENROUTER_API_KEY" => "broker-placeholder",
           "ANTHROPIC_API_KEY" => "anthropic-placeholder" }.freeze

  def responses_body(script, status: "completed", usage: {}, incomplete: nil)
    call = { "type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "compose",
             "arguments" => JSON.generate("script" => script) }
    { "id" => "resp_1", "object" => "response", "status" => status, "output" => script ? [call] : [],
      "usage" => usage, "incomplete_details" => incomplete }.compact
  end

  def messages_body(script)
    { "id" => "msg_1", "type" => "message", "role" => "assistant", "model" => "claude-opus-5-5",
      "content" => [{ "type" => "tool_use", "id" => "toolu_1", "name" => "compose", "input" => { "script" => script } }],
      "stop_reason" => "tool_use", "usage" => { "input_tokens" => 20, "cache_read_input_tokens" => 9_000, "output_tokens" => 300 } }
  end

  def chat_body(script, usage:, finish: "tool_calls")
    call = { "id" => "call_1", "type" => "function", "function" => { "name" => "compose", "arguments" => JSON.generate("script" => script) } }
    { "id" => "gen-1", "object" => "chat.completion", "usage" => usage,
      "choices" => [{ "index" => 0, "finish_reason" => finish, "message" => { "role" => "assistant", "content" => nil, "tool_calls" => [call] } }] }
  end

  def wired(ref, *bodies)
    wire = RecordingAdapter.new(*bodies)
    lane = route(ref)
    [E2E::ComposeBench::Probe.new(client: E2E::ManualClient.for(lane, env: KEYS, adapter: wire), route: lane, row: shipped_row), wire]
  end

  # THE DIRECT FLOOR IS THE ONE MEASURED: `deepseek/deepseek-flash` samples on the official API
  # under its own key and id, within the bench's timeout, and the sample keeps the provider's
  # token counts and its finish.
  def test_the_direct_floor_samples_on_the_official_api_and_records_its_usage_and_finish
    probe, wire = wired("deepseek/deepseek-flash",
      responses_body(CANONICAL.fetch("O4"), usage: { "input_tokens" => 5_100, "output_tokens" => 700, "total_tokens" => 5_800 }))
    sample = probe.sample(Objectives.find("O4"), 1)

    request = wire.requests.fetch(0)
    assert_equal "https://api.deepseek.com/responses", request.fetch(:url)
    assert_equal "Bearer direct-placeholder", request.fetch(:headers).fetch("Authorization")
    assert_in_delta E2E::ManualClient::TIMEOUT_SECONDS, request.fetch(:timeout), 0, "the bench's timeout reaches the call"
    assert_equal "deepseek-flash", JSON.parse(request.fetch(:body)).fetch("model")
    assert sample["first_time_right"], sample.inspect
    assert_equal "deepseek/deepseek-flash", sample["model"]
    assert_equal({ "input_tokens" => 5_100, "output_tokens" => 700 }, sample["usage"])
    assert_equal "completed", sample["finish"]
  end

  # EVERY CALL KEEPS ITS SPEND AND ITS FINISH: the broker's chat wire counts prompt/completion
  # tokens and adds its charge; the repair call is recorded beside the first under its own names.
  def test_the_first_call_and_the_repair_each_record_usage_and_finish
    probe, wire = wired("openrouter/z-ai/glm-5.3-flash",
      chat_body('g.tool({ name: "bash", command: "bin/rails test" });',
        usage: { "prompt_tokens" => 4_800, "completion_tokens" => 900, "total_tokens" => 5_700, "cost" => 0.0021 }),
      chat_body(CANONICAL.fetch("O4"), usage: { "prompt_tokens" => 5_300, "completion_tokens" => 400, "cost" => 0.0012 }, finish: "stop"))
    sample = probe.sample(Objectives.find("O4"), 1)

    assert_equal "https://openrouter.ai/api/v1/chat/completions", wire.requests.fetch(0).fetch(:url)
    assert_equal "z-ai/glm-5.3-flash", JSON.parse(wire.requests.fetch(0).fetch(:body)).fetch("model")
    assert_equal "valid", sample["repaired"], sample.inspect
    assert_equal({ "input_tokens" => 4_800, "output_tokens" => 900, "cost" => 0.0021 }, sample["usage"])
    assert_equal "tool_calls", sample["finish"]
    assert_equal({ "input_tokens" => 5_300, "output_tokens" => 400, "cost" => 0.0012 }, sample["repaired_usage"])
    assert_equal "stop", sample["repaired_finish"]
  end

  # THE REPAIR ROUND IS THE RESPONSES WIRE'S OWN on the direct lane: the refused call as a
  # `function_call` item and the refusal as a `function_call_output` carrying only its own fields
  # (the item has no `name`; the chat wire's lowering never read one).
  def test_the_repair_round_on_the_direct_lane_is_well_formed_responses_items
    probe, wire = wired("deepseek/deepseek-flash",
      responses_body('g.tool({ name: "bash", command: "bin/rails test" });'), responses_body(CANONICAL.fetch("O4")))
    sample = probe.sample(Objectives.find("O4"), 1)

    assert_equal "valid", sample["repaired"], sample.inspect
    _ask, called, refused = JSON.parse(wire.requests.fetch(1).fetch(:body)).fetch("input")
    assert_equal %w[arguments call_id name type], called.keys.sort
    assert_equal %w[call_id output type], refused.keys.sort
    assert_equal ["function_call_output", "call_1"], refused.values_at("type", "call_id")
  end

  # AN OPUS DRAW CARRIES THE KERNEL'S TWO CACHE MARKERS ON EVERY CALL, the repair's included: the
  # system block's (tools and system cached as one prefix) and the tail on the last entry — so the
  # repair round's replayed first ask is unmarked and reads from the prefix the first call wrote.
  def test_an_opus_draw_and_its_repair_each_carry_the_two_cache_markers
    probe, wire = wired("anthropic/claude-opus-5-5",
      messages_body('g.tool({ name: "bash", command: "bin/rails test" });'), messages_body(CANONICAL.fetch("O4")))
    sample = probe.sample(Objectives.find("O4"), 1)

    assert_equal "valid", sample["repaired"], sample.inspect
    bodies = wire.requests.map { |request| JSON.parse(request.fetch(:body)) }
    assert_equal 2, bodies.size
    bodies.each_with_index do |body, i|
      assert_equal({ "type" => "ephemeral" }, body.fetch("system").last["cache_control"], "call #{i + 1}: the stable marker")
      assert_equal({ "type" => "ephemeral" }, body.fetch("messages").last.fetch("content").last["cache_control"], "call #{i + 1}: the tail")
      assert_equal 2, JSON.generate(body).scan("\"cache_control\"").size, "call #{i + 1}: two breakpoints, no more"
    end
    refute_includes JSON.generate(bodies.last.fetch("messages").first), "cache_control", "the replayed first ask is unmarked"
    assert_equal({ "input_tokens" => 9_020, "output_tokens" => 300, "cache_read_tokens" => 9_000 }, sample["usage"])
  end

  # AN EXHAUSTED CAP READS THE SAME ON BOTH WIRES: the Responses family says `incomplete` and puts
  # the reason in its detail; the gem's classifier names the budget, and the readout reads the cap.
  def test_an_exhausted_cap_on_the_responses_wire_reads_as_the_cap
    probe, = wired("deepseek/deepseek-flash",
      responses_body(nil, status: "incomplete", usage: { "input_tokens" => 5_000, "output_tokens" => 4_096 },
        incomplete: { "reason" => "max_output_tokens" }))
    sample = probe.sample(Objectives.find("O7"), 1)

    refute sample["reached"]
    assert_equal %w[incomplete max_output_tokens output_budget_exhausted],
      sample.values_at("finish", "finish_detail", "finish_quality")
    assert_includes E2E::ComposeBench::Report.markdown("R-WO", "deepseek/deepseek-flash", [sample]),
      "- O7#1: no compose call ({}, finish incomplete at the 4096-token cap)"
  end

  # THE READOUT JSON KEEPS THE SPEND AND THE FINISH of every sample it merges.
  def test_the_readout_json_keeps_every_samples_usage_and_finish
    probe, = wired("openrouter/z-ai/glm-5.3-flash",
      chat_body(CANONICAL.fetch("O2"), usage: { "prompt_tokens" => 4_000, "completion_tokens" => 300, "cost" => 0.001 }))
    sample = probe.sample(Objectives.find("O2"), 1)
    Dir.mktmpdir("bench") do |dir|
      E2E::ComposeBench::Report.write_all([sample], dir: dir, captures: File.join(dir, "captures"))
      kept = JSON.parse(File.read(File.join(dir, "compose_matrix.json"), encoding: Encoding::UTF_8)).fetch(0)
      assert_equal [{ "input_tokens" => 4_000, "output_tokens" => 300, "cost" => 0.001 }, "tool_calls"],
        kept.values_at("usage", "finish")
    end
  end

  def test_the_readout_writes_one_table_per_row_model_and_style_and_the_captures
    samples = [
      { "objective" => "O2", "row" => "R-WO", "model" => "x/y", "sample" => 1, "reached" => true, "valid_first" => true,
        "exact_edges" => true, "exact_reads" => true, "first_time_right" => true, "valid_after_repair" => true,
        "right_after_repair" => true, "script" => CANONICAL.fetch("O2"), "params" => {}, "silent" => [], "called" => { "compose" => 1 } },
      { "objective" => "O2", "row" => "R-WO", "model" => "x/y", "sample" => 2, "reached" => true, "valid_first" => false,
        "first_time_right" => false, "refusal" => "script_error", "detail" => 'g.tool: unknown option "command".',
        "loud" => "unknown_option", "group" => "g.tool: unknown option \"…\".", "script" => "bad", "params" => {},
        "repaired" => "valid", "valid_after_repair" => true, "right_after_repair" => false, "called" => { "compose" => 1 } },
      { "objective" => "O5", "row" => "R-WO", "model" => "x/y", "sample" => 1, "reached" => false, "compose_zero" => true,
        "called" => { "read_file" => 1 } },
      { "objective" => "O2", "row" => "R-WO", "model" => "x/y", "style" => "claude", "sample" => 1, "reached" => true,
        "valid_first" => true, "first_time_right" => true, "script" => CANONICAL.fetch("O2"), "params" => {},
        "silent" => [], "called" => { "compose" => 1 } },
    ]
    Dir.mktmpdir("bench") do |dir|
      captures = File.join(dir, "captures")
      E2E::ComposeBench::Report.write_captures(samples, dir: captures)
      manifest = JSON.parse(File.read(File.join(captures, "manifest.json"), encoding: Encoding::UTF_8))
      assert_equal [true, false, true], manifest.map { |entry| entry["composed"] }
      # A sample with no `style` is the baseline, and the baseline's stem is
      # today's spelling — the landed captures are never re-named; another
      # style's stem carries its word before the index.
      assert_equal %w[o2.r-wo.x-y.1.js o2.r-wo.x-y.2.js o2.r-wo.x-y.claude.1.js], Dir.children(captures).grep(/\.js\z/).sort
      assert_equal %w[nexus nexus claude], manifest.map { |entry| entry["style"] }
      assert_equal %w[o2.r-wo.x-y.1 o2.r-wo.x-y.2 o2.r-wo.x-y.claude.1], manifest.map { |entry| entry["objective"] }
      assert_equal Tools::NAMES + %w[task ask], manifest.first["tools"].map { |tool| tool.dig("function", "name") },
        "the replay declares the style's set beside compose"
      assert_equal Tools::NAMES + %w[Agent AskUserQuestion], manifest.last["tools"].map { |tool| tool.dig("function", "name") }
      assert_equal "nexus.graph.task", manifest.last["tools"][-2]["canonical"], "the alias facts ride the manifest for the door"

      E2E::ComposeBench::Report.write_all(samples, dir: dir, captures: captures)
      assert_equal %w[results-r-wo-x-y-claude.md results-r-wo-x-y-nexus.md],
        Dir.children(dir).grep(/\Aresults-/).sort, "one table per (row × model × style)"
      table = File.read(File.join(dir, "results-r-wo-x-y-nexus.md"), encoding: Encoding::UTF_8)
      assert_includes table, "# compose bench — row R-WO, model `x/y`, style `nexus`"
      assert_includes table, "| O2 grep-then-edit | yes | 2/2 | 1/2 | 1/2 | 1/2 | 1/2 | 2/2 | 1/2 | unknown_option×1 | — |"
      assert_includes table, "| O5 single-read | control | read_file×1 | compose 0: 1/1 |"
      assert_includes table, "- O2: FAIL valid-first 1/2, correct-shape 1/2"
      assert_includes table, "- O5: PASS (composed 0)"
      assert_includes table, "1 × `g.tool: unknown option \"…\".` (O2#2)"
      claude = File.read(File.join(dir, "results-r-wo-x-y-claude.md"), encoding: Encoding::UTF_8)
      assert_includes claude, "| O2 grep-then-edit | yes | 1/1 | 1/1 |"
      refute_includes claude, "O5", "the other style's cells are not this table's"
    end
  end

  # THE TEXT BENCH'S OWN COLUMNS, added beside the gate's and never in place of one: per objective
  # the usable count, the expanded right count over the samples that are not opaque, the opaque
  # count, and the rehearsed right count over the first scripts that built; per cell the same pooled
  # over every objective but the control — the rehearsed count with its world-dependent draws —
  # each endpoint's rate over the first scripts that built, and every sample's first-call finish as
  # length, error or other, so an arm's exhausted budgets are read beside its numbers.
  def test_the_readout_adds_usable_the_expanded_reading_the_endpoints_and_the_finishes
    endpoints = lambda do |wrapped, looped, labelled|
      { "whole_plan_wrapper" => wrapped, "ungrouped_loop" => looped, "authored_labels" => labelled, "success_filter" => false }
    end
    built = { "reached" => true, "valid_first" => true, "first_time_right" => false, "silent" => ["missing_steps"],
              "usable" => true, "opaque" => false, "expanded" => { "first_time_right" => false }, "finish" => "tool_calls",
              "rehearsed" => { "first_time_right" => false, "world_dependent" => false } }
    samples = [
      built.merge("sample" => 1, "first_time_right" => true, "silent" => [], "expanded" => { "first_time_right" => true },
        "endpoints" => endpoints.call(false, false, true), "rehearsed" => { "first_time_right" => true, "world_dependent" => false }),
      built.merge("sample" => 2, "opaque" => true, "endpoints" => endpoints.call(false, true, false), "finish" => "stop",
        "rehearsed" => { "first_time_right" => true, "world_dependent" => true }).except("expanded"),
      built.merge("sample" => 3, "usable" => false, "unusable" => "stage script-1 refused script_error",
        "endpoints" => endpoints.call(true, false, false)),
      { "objective" => "O4", "sample" => 1, "reached" => false, "finish" => "length", "max_output_tokens" => 4096 },
      { "objective" => "O4", "sample" => 2, "reached" => false, "error" => "HTTPX::ReadTimeoutError: timed out" },
      { "objective" => "O5", "sample" => 1, "reached" => false, "compose_zero" => true, "called" => { "read_file" => 1 },
        "finish" => "tool_calls" },
    ].map { |sample| { "objective" => "O2", "row" => "R-WO", "model" => "x/y" }.merge(sample) }
    table = E2E::ComposeBench::Report.markdown("R-WO", "x/y", samples)

    assert_includes table, "| right after repair | loud | silent | usable | expanded right | opaque | rehearsed right |"
    assert_includes table, "| O2 grep-then-edit | yes | 3/3 | 3/3 | 0/3 | 0/3 | 1/3 | 0/3 | 0/3 | — | missing_steps×2 | 2/3 | 1/2 | 1 | 2/3 |"
    assert_includes table, "| O4 background-suite | yes | 0/2 | 0/2 | 0/2 | 0/2 | 0/2 | 0/2 | 0/2 | — | — | 0/2 | 0/2 | 0 | 0/0 |"
    assert_includes table, "| O5 single-read | control | read_file×1 | compose 0: 1/1 | — | — | — | — | — | — | — | — | — | — | — |"
    assert_includes table, "- O2: FAIL valid-first 3/3, correct-shape 1/3", "the gate reads what it always read"
    assert_includes table, "## pooled over every objective but the control\n\n" \
                           "- usable: 2/5\n" \
                           "- first-time right: static 1/5, expanded 1/4 (1 opaque, counted out); rehearsed 2/3 (1 world-dependent)\n" \
                           "- endpoints over the 3 first scripts that built: whole_plan_wrapper 1/3, ungrouped_loop 1/3, " \
                           "authored_labels 1/3, success_filter 0/3\n" \
                           "- first-call finish, every sample: length 1, error 1, other 4\n"
    assert_includes table, "- O2#3: valid; silent: missing_steps; not usable: stage script-1 refused script_error"
  end

  # A RUN REPLACES ITS OWN CELLS AND KEEPS THE OTHERS: the matrix is run
  # one row or one model at a time when the budget says so, and four such
  # runs must leave the whole matrix in the artifact and the captures —
  # the first matrix left only its last run's sixteen scripts behind.
  def test_a_partial_run_replaces_its_cells_and_keeps_the_rest
    sample = lambda do |row, model, index, script|
      { "objective" => "O2", "row" => row, "model" => model, "sample" => index, "reached" => true,
        "valid_first" => true, "first_time_right" => true, "script" => script, "params" => {}, "called" => { "compose" => 1 } }
    end
    Dir.mktmpdir("bench") do |dir|
      captures = File.join(dir, "captures")
      first = [sample.call("R-WO", "x/y", 1, "one"), sample.call("R-WO+N", "x/y", 1, "two")]
      E2E::ComposeBench::Report.write_all(first, dir: dir, captures: captures)

      again = [sample.call("R-WO+N", "x/y", 1, "two-again"), sample.call("R-WO+N", "x/y", 2, "three")]
      E2E::ComposeBench::Report.write_all(again, dir: dir, captures: captures)

      matrix = JSON.parse(File.read(File.join(dir, "compose_matrix.json")))
      assert_equal [["R-WO", 1, "one"], ["R-WO+N", 1, "two-again"], ["R-WO+N", 2, "three"]],
        matrix.map { |s| s.values_at("row", "sample", "script") }
      assert_equal %w[o2.r-wo-n.x-y.1.js o2.r-wo-n.x-y.2.js o2.r-wo.x-y.1.js], Dir.children(captures).grep(/\.js\z/).sort
      assert_equal "two-again", File.read(File.join(captures, "o2.r-wo-n.x-y.1.js"))
      manifest = JSON.parse(File.read(File.join(captures, "manifest.json"), encoding: Encoding::UTF_8))
      assert_equal %w[o2.r-wo.x-y.1 o2.r-wo-n.x-y.1 o2.r-wo-n.x-y.2], manifest.map { |entry| entry["objective"] },
        "row order, then model, objective and sample — the readout's order, not the alphabet's"

      # A cell is (row, model, OBJECTIVE): one objective re-run alone keeps
      # its siblings' samples and captures in the same row and model.
      only_o5 = [sample.call("R-WO+N", "x/y", 1, "five").merge("objective" => "O5")]
      E2E::ComposeBench::Report.write_all(only_o5, dir: dir, captures: captures)
      matrix = JSON.parse(File.read(File.join(dir, "compose_matrix.json")))
      assert_equal [%w[R-WO O2], %w[R-WO+N O2], %w[R-WO+N O2], %w[R-WO+N O5]], matrix.map { |s| s.values_at("row", "objective") }
      assert_equal %w[o2.r-wo-n.x-y.1.js o2.r-wo-n.x-y.2.js o2.r-wo.x-y.1.js o5.r-wo-n.x-y.1.js],
        Dir.children(captures).grep(/\.js\z/).sort

      # A cell is (row, model, STYLE, objective): a style's run keeps the
      # other styles' samples and captures, and a sample written before the
      # axis existed (no `style`) is the baseline's cell.
      claude = [sample.call("R-WO", "x/y", 1, "styled").merge("style" => "claude")]
      E2E::ComposeBench::Report.write_all(claude, dir: dir, captures: captures)
      E2E::ComposeBench::Report.write_all([sample.call("R-WO", "x/y", 1, "one-again")], dir: dir, captures: captures)
      matrix = JSON.parse(File.read(File.join(dir, "compose_matrix.json")))
      assert_equal [["R-WO", "nexus", "one-again"], ["R-WO", "claude", "styled"], ["R-WO+N", "nexus", "two-again"],
                    ["R-WO+N", "nexus", "three"], ["R-WO+N", "nexus", "five"]],
        matrix.map { |s| [s["row"], s["style"], s["script"]] }, "the style rides every sample the matrix keeps, nexus first"
      assert_equal %w[o2.r-wo-n.x-y.1.js o2.r-wo-n.x-y.2.js o2.r-wo.x-y.1.js o2.r-wo.x-y.claude.1.js o5.r-wo-n.x-y.1.js],
        Dir.children(captures).grep(/\.js\z/).sort
      assert_equal "one-again", File.read(File.join(captures, "o2.r-wo.x-y.1.js"))
      assert_equal "styled", File.read(File.join(captures, "o2.r-wo.x-y.claude.1.js"))
    end
  end

  private

    # The shipped row — the registry's own `compose` bytes — found by name whatever id a tree gives
    # it, so a test of the probe's transport depends on no row's id.
    def shipped_row = Rows.find("shipped")
end
