require "test_helper"

# THE STEP VALUES: one `to_h` per shape is the whole codec, and the
# builder places steps in the order they are written. The kernel reads
# the same shapes (`Step.from_h`); the contract pack pins them as one.
class StepsTest < Minitest::Test
  Steps = CybrosAgent::Steps

  def test_each_value_renders_its_verb_and_only_the_fields_it_was_given
    assert_equal({ "tool" => { "name" => "bash", "input" => { "command" => "t" }, "key" => "tests" } },
      Steps::Tool.new(name: "bash", input: { "command" => "t" }, key: "tests").to_h)
    assert_equal({ "model" => { "prompt" => "p" } }, Steps::Model.new(prompt: "p").to_h,
      "absent stays absent; an attached step carries no detached")
    assert_equal({ "ask" => { "prompt" => "?", "timeout_ms" => 5, "detached" => true } },
      Steps::Ask.new(prompt: "?", timeout_ms: 5, detached: true).to_h)
    assert_equal({ "ask" => { "prompt" => "?", "options" => %w[a b], "multi" => true } },
      Steps::Ask.new(prompt: "?", options: %w[a b], multi: true).to_h, "the choices ride as data")
    assert_equal({ "tool" => { "name" => "bash", "input" => {}, "detached" => true } },
      Steps::Tool.new(name: "bash", detached: true).to_h, "the door's per-step word is the node column's")
  end

  def test_lifetime_is_independent_of_detachment_and_inherits_when_omitted
    steps = Steps.build do |s|
      s.parallel(lifetime: "turn") do |p|
        p.tool "bash", detached: true, lifetime: "conversation"
        p.model "review", detached: true, lifetime: "turn"
        p.ask "which version?", lifetime: "turn"
      end
      s.model "synthesize"
    end

    fan, sibling = Steps.envelope(steps)
    assert_equal "turn", fan.fetch("lifetime")
    assert_equal "conversation", fan.fetch("parallel")[0].dig("tool", "lifetime")
    assert_equal true, fan.fetch("parallel")[0].dig("tool", "detached")
    assert_equal "turn", fan.fetch("parallel")[1].dig("model", "lifetime")
    assert_equal true, fan.fetch("parallel")[1].dig("model", "detached")
    assert_equal "turn", fan.fetch("parallel")[2].dig("ask", "lifetime")
    refute sibling.fetch("model").key?("lifetime"), "Nexus resolves omission from the authoring context"
  end

  def test_passive_result_delivery_is_independent_of_waiting_and_lifetime
    steps = Steps.build do |s|
      s.parallel(wake: "passive") do |p|
        p.tool "read", detached: true, lifetime: "conversation"
        p.model "review", wake: "auto", lifetime: "turn"
        p.ask "which version?", wake: "passive"
        p.script "return params", wake: "passive"
      end
      s.model "synthesize"
    end

    fan, sibling = Steps.envelope(steps)
    assert_equal "passive", fan.fetch("wake")
    tool, model, ask, script = fan.fetch("parallel")
    refute tool.fetch("tool").key?("wake"), "omission inherits the enclosing delivery policy"
    assert_equal "conversation", tool.dig("tool", "lifetime")
    assert_equal "auto", model.dig("model", "wake")
    assert_equal "turn", model.dig("model", "lifetime")
    assert_equal "passive", ask.dig("ask", "wake")
    assert_equal "passive", script.dig("script", "wake")
    refute sibling.fetch("model").key?("wake")
  end

  def test_later_wait_names_existing_work_without_recreating_it
    steps = Steps.build do |s|
      s.wait task: "investigate", agent_loop: "019f0000-0000-7000-8000-000000000601",
        key: "report", timeout_ms: 30_000, on_failure: "absorb"
      s.model "Summarize the report", results: ["report"]
    end

    wait, model = Steps.envelope(steps)
    assert_equal({ "task" => "investigate", "agent_loop" => "019f0000-0000-7000-8000-000000000601",
                   "key" => "report", "timeout_ms" => 30_000, "on_failure" => "absorb" }, wait.fetch("wait"))
    assert_equal ["report"], model.dig("model", "results")
    assert_equal({ "task" => "work" }, Steps::Wait.new(task: "work").to_h.fetch("wait"))
  end

  # `retry` is a reserved word: the keyword is `retries:`, the wire stays `retry`.
  def test_retries_is_the_keyword_and_retry_the_wire_field
    rendered = Steps::Model.new(prompt: "review", retries: 2, on_failure: "propagate", visibility: "hidden").to_h
    assert_equal({ "prompt" => "review", "retry" => 2, "on_failure" => "propagate",
                   "visibility" => "hidden" }, rendered.fetch("model"))
    assert_equal 2, Steps::Model.new(prompt: "review", retries: 2).retries
  end

  def test_retry_budget_is_not_an_option_for_tool_or_ask_steps
    assert_raises(ArgumentError) { Steps::Tool.new(name: "bash", retries: 2) }
    assert_raises(ArgumentError) { Steps::Ask.new(prompt: "which?", retries: 2) }
    assert_raises(ArgumentError) { Steps.build { |s| s.tool "bash", retries: 2 } }
  end

  def test_a_model_step_carries_the_surface_it_names_and_nothing_it_does_not
    rendered = Steps::Model.new(prompt: "p", key: "k", model: { "model" => "m/x" }, tools: [],
      instructions: "be brief", configuration: { "temperature" => 0 },
      compaction: { "mode" => "kernel" }, fan_on_failure: "absorb").to_h
    assert_equal %w[prompt key model tools instructions configuration compaction fan_on_failure],
      rendered.fetch("model").keys
  end

  def test_the_builder_places_steps_in_written_order_with_a_fan_and_a_nested_sequence
    steps = Steps.build do |s|
      s.parallel(until: "any", losers: "run_out", key: "race") do |p|
        p.tool "bash", input: { "command" => "t" }, key: "tests"
        p.sequence do |q|
          q.tool "bash", input: { "command" => "l" }, key: "lint"
          q.model "read the lint", key: "review"
        end
      end
      s.model "sum it", key: "summary"
      s.ask "right?", key: "gate"
    end

    assert_equal [Steps::Parallel, Steps::Model, Steps::Ask], steps.map(&:class)
    assert_equal [
      { "parallel" => [
          { "tool" => { "name" => "bash", "input" => { "command" => "t" }, "key" => "tests" } },
          [{ "tool" => { "name" => "bash", "input" => { "command" => "l" }, "key" => "lint" } },
           { "model" => { "prompt" => "read the lint", "key" => "review" } }],
        ], "until" => "any", "losers" => "run_out", "key" => "race" },
      { "model" => { "prompt" => "sum it", "key" => "summary" } },
      { "ask" => { "prompt" => "right?", "key" => "gate" } },
    ], Steps.envelope(steps)
  end

  def test_a_default_group_writes_no_until_and_a_quorum_is_a_number
    plain = Steps.build { |s| s.parallel { |p| p.ask "a"; p.ask "b" } }.first
    assert_equal({ "parallel" => [{ "ask" => { "prompt" => "a" } }, { "ask" => { "prompt" => "b" } }] }, plain.to_h)
    quorum = Steps::Parallel.new(members: [Steps::Ask.new(prompt: "a")], until: 2, on_failure: "absorb")
    assert_equal({ "parallel" => [{ "ask" => { "prompt" => "a" } }], "until" => 2, "on_failure" => "absorb" },
      quorum.to_h)
  end

  # No raw edge, barrier or deliverable: the values have no field for
  # any of them, so the old grammar cannot be written by accident.
  def test_no_value_takes_an_edge_word
    %i[depends_on input_from deliverable mode quorum_k loser_policy detach run_in_background].each do |word|
      assert_raises(ArgumentError, word.to_s) { Steps::Model.new(prompt: "p", word => ["x"]) }
      assert_raises(ArgumentError, word.to_s) { Steps::Tool.new(name: "bash", word => ["x"]) }
    end
    assert_raises(ArgumentError) { Steps::Parallel.new(members: [], mode: "any") }
  end

  def test_script_inputs_and_additive_waits_keep_their_wire_order
    steps = Steps.build do |s|
      s.tool "read", key: "a"
      s.tool "read", key: "b", after: ["a"]
      s.script "return results.map(r => r.output)", key: "reduce", results: %w[b a],
        params: { "limit" => 2 }, model_defaults: { "model" => { "model" => "dev/mock-text" } }
      s.model "report", after: ["b"], results: ["reduce"]
    end
    wire = Steps.envelope(steps)
    assert_equal ["a"], wire[1].dig("tool", "after")
    assert_equal %w[b a], wire[2].dig("script", "results")
    assert_equal "dev/mock-text", wire[2].dig("script", "model_defaults", "model", "model")
    assert_equal ["reduce"], wire[3].dig("model", "results")
    assert_equal ["b"], wire[3].dig("model", "after")
    assert_raises(ArgumentError) { Steps::Tool.new(name: "read", results: ["a"]) }
    assert_raises(ArgumentError) { Steps::Script.new(script: "return null", retries: 1) }
  end

  def test_the_envelope_passes_wire_hashes_through_and_refuses_a_non_array
    assert_equal [{ "model" => { "prompt" => "p" } }, { "ask" => { "prompt" => "?" } }],
      Steps.envelope([{ "model" => { "prompt" => "p" } }, Steps::Ask.new(prompt: "?")])
    assert_raises(ArgumentError) { Steps.envelope(nil) }
  end
end
