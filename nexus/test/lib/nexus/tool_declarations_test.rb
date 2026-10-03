require "test_helper"

# One declared set's rules, wherever it is authored — and the ONE
# implementation of "a subset of an inherited set, by name" that a branch
# (`BranchTools.narrow`) and a turn (the materialization seed) share.
class Nexus::ToolDeclarationsTest < ActiveSupport::TestCase
  Declarations = Nexus::ToolDeclarations

  READ = { "type" => "function",
           "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } }.freeze
  WRITE = { "type" => "function",
            "function" => { "name" => "write_file", "parameters" => { "type" => "object" } } }.freeze
  FLAT = { "name" => "grep", "parameters" => { "type" => "object" } }.freeze

  test "names reads both spellings and nothing from nothing" do
    assert_equal %w[read_file grep], Declarations.names([READ, FLAT])
    assert_equal [], Declarations.names(nil)
    assert_equal [], Declarations.names([{ "type" => "function" }, "not a hash"])
  end

  test "narrow keeps the named entries in declaration order; nil is the whole set" do
    assert_equal [WRITE], Declarations.narrow([READ, WRITE], %w[write_file])
    assert_equal [READ, WRITE], Declarations.narrow([READ, WRITE], %w[write_file read_file]),
      "the declaration's order, not the caller's — a set at the front of a cached prefix"
    assert_equal [READ, WRITE], Declarations.narrow([READ, WRITE], nil)
    assert_equal [], Declarations.narrow([READ], %w[compose])
  end

  test "undeclared is the first name the set cannot give" do
    assert_nil Declarations.undeclared([READ, WRITE], %w[read_file write_file])
    assert_equal "compose", Declarations.undeclared([READ], %w[read_file compose task])
    assert_equal "read_file", Declarations.undeclared(nil, %w[read_file]),
      "no declaration declares nothing"
  end

  # ── the alias: a THIRD declaration shape ───────── An entry carrying `canonical` is the declaring
  # agent's own SPELLING of a kernel tool: the canonical stays the kernel's, the store holds the
  # profile's RENDER, and a call made under the alias runs under the kernel's wire name.

  COMPOSE = Nexus::ToolRegistry.function_definition("nexus.graph.compose")
  TASK = Nexus::ToolRegistry.function_definition("nexus.graph.task")
  AGENT_SENTENCE = "true (the default): the task runs in the background and its answer is delivered " \
    "to you in a later message. false: this turn waits and the answer is this call's result.".freeze
  AGENT = { "type" => "function", "function" => { "name" => "Agent" }, "canonical" => "nexus.graph.task",
            "params" => { "run_in_background" => { "maps_to" => "wait", "invert" => true,
                                                   "description" => AGENT_SENTENCE } } }.freeze
  SPAWN = { "name" => "spawn_agent", "canonical" => "nexus.graph.task", "omit" => ["wait"],
            "description" => "Give one job to a new agent with {{task}}; {{compose}} is for shape. " \
              "There is no wait verb: the answer reaches you later." }.freeze
  ASK_USER = { "name" => "AskUserQuestion", "canonical" => "nexus.human.ask" }.freeze

  def alias_entry(**over) = AGENT.merge(over.transform_keys(&:to_s))

  def with_params(params) = alias_entry(params: params)

  test "intersection keeps canonical aliases and current order without restoring absent tools" do
    assert_equal %w[Agent read_file], Declarations.intersection_names([AGENT, WRITE, READ], inherited: [READ, TASK])
    assert_equal %w[task], Declarations.intersection_names([TASK, WRITE], inherited: [AGENT])
    assert_equal [], Declarations.intersection_names([READ, TASK], inherited: [])
    assert_equal [], Declarations.intersection_names(nil, inherited: [TASK])
    assert_equal [], Declarations.intersection_names([WRITE], inherited: [READ])
    reused_alias = AGENT.merge("canonical" => "nexus.human.ask")
    assert_equal [], Declarations.intersection_names([reused_alias], inherited: [AGENT]),
      "a reused alias name cannot grant a different kernel tool"
  end

  test "refusal is nil for a lawful set, and answers each of the six alias words" do
    assert_nil Declarations.refusal([READ, COMPOSE, AGENT, SPAWN, ASK_USER])
    assert_nil Declarations.refusal([TASK, AGENT, SPAWN]), "several spellings of one canonical, plain included"
    assert_nil Declarations.refusal([with_params({ "later" => { "maps_to" => "wait" } })]),
      "a plain rename needs no description"

    assert_equal "alias_canonical_unknown", Declarations.refusal([alias_entry(canonical: "rho.fs.read")])
    assert_equal "alias_name_reserved",
      Declarations.refusal([{ "name" => "task", "canonical" => "nexus.graph.compose" }]),
      "a kernel spelling is never re-pointed"
    assert_equal "alias_name_reserved",
      Declarations.refusal([{ "name" => "nexus.graph.task", "canonical" => "nexus.human.ask" }])
    assert_equal "duplicate_tool_name", Declarations.refusal([READ, READ])
    assert_equal "duplicate_tool_name", Declarations.refusal([AGENT, READ.merge("function" => { "name" => "Agent" })]),
      "an alias may not collide with a runner tool in the same set"
    assert_equal "alias_param_unknown", Declarations.refusal([with_params({ "bg" => { "maps_to" => "background" } })])
    assert_equal "alias_param_unknown", Declarations.refusal([with_params({ "prompt" => { "maps_to" => "wait" } })]),
      "an alias parameter may not shadow a kept kernel parameter"
    assert_equal "alias_param_unknown", Declarations.refusal([alias_entry(omit: ["nothing"])])
    assert_equal "alias_param_unknown", Declarations.refusal([alias_entry(omit: ["wait"])]),
      "a mapped parameter cannot also be omitted"
    assert_equal "alias_invert_needs_boolean",
      Declarations.refusal([with_params({ "text" => { "maps_to" => "prompt", "invert" => true, "description" => "x" } })])
    assert_equal "alias_param_description_required",
      Declarations.refusal([with_params({ "run_in_background" => { "maps_to" => "wait", "invert" => true } })]),
      "the kernel's sentence for wait is wrong under inversion"
  end

  test "refusal keeps the kernel-name word, and reads an alias's function block as its render" do
    assert_equal "kernel_tool_redefined", Declarations.refusal([{ "name" => "send", "parameters" => {} }]),
      "`send` is a declared live tool: a paraphrase redefines it"
    assert_equal "kernel_tool_redefined", Declarations.refusal([{ "name" => "compose", "parameters" => {} }])
    rendered = Declarations.render([COMPOSE, AGENT]).last
    assert_nil Declarations.refusal([COMPOSE, rendered]), "the stored form validates as itself"
    other_bytes = rendered.merge("function" => rendered["function"].merge("description" => "other"))
    assert_equal "kernel_tool_redefined", Declarations.refusal([COMPOSE, other_bytes])
    assert_equal "invalid", Declarations.refusal([{ "canonical" => "nexus.graph.task" }]), "an alias needs a name"
    assert_equal "invalid", Declarations.refusal([alias_entry(params: "wait")])
  end

  test "canonical sorts alias entries by name among the rest" do
    assert_equal %w[Agent compose read_file], Declarations.names(Declarations.canonical([READ, AGENT, COMPOSE]))
  end

  test "alias? and canonical_of read the entry's facts in both spellings" do
    assert Declarations.alias?(AGENT)
    assert Declarations.alias?(SPAWN)
    refute Declarations.alias?(READ)
    refute Declarations.alias?(COMPOSE)
    assert_equal "nexus.graph.task", Declarations.canonical_of(AGENT)
    assert_equal "nexus.graph.task", Declarations.canonical_of(TASK)
    assert_equal "nexus.graph.compose", Declarations.canonical_of(COMPOSE)
    assert_nil Declarations.canonical_of(READ)
    assert_nil Declarations.canonical_of(FLAT)
  end

  test "render of a set with no alias is the input, byte for byte" do
    set = [COMPOSE, READ, TASK, FLAT]
    assert_equal set, Declarations.render(set)
    assert_equal Nexus::ToolRegistry.function_definition("task"), Declarations.render([TASK]).sole
    assert_equal [], Declarations.render([])
  end

  test "render spells the set's names into every kernel text and maps the alias's parameters" do
    compose, agent = Declarations.render([COMPOSE, AGENT])

    assert_includes compose.dig("function", "description"), "you need neither compose nor\nAgent."
    refute_includes compose.dig("function", "description"), "nor\ntask"
    assert_equal %w[type function canonical params], agent.keys
    assert_equal "Agent", agent.dig("function", "name")
    assert_equal AGENT.slice("canonical", "params"), agent.slice("canonical", "params"),
      "the resolution facts ride beside the function block"
    description = agent.dig("function", "description")
    assert_includes description, "put several `Agent` calls in ONE message"
    assert_includes description, "→ one message: Agent({prompt:", "the worked example spells the alias"
    assert_equal ["`task` attribute"], description.scan(/`task` \w+/), "the envelope's attribute is not the tool"
    refute_match(/`(?:read|grep|start_process)`/, description, "the kernel's text names no runner tool (C-S2)")
    parameters = agent.dig("function", "parameters")
    assert_equal %w[prompt lifetime wake run_in_background tools], parameters.fetch("properties").keys,
      "renamed in place, so the prefix keeps its order"
    assert_equal({ "type" => "boolean", "default" => true, "description" => AGENT_SENTENCE },
      parameters.dig("properties", "run_in_background"), "the default is inverted, the sentence replaced")
    assert_equal ["prompt"], parameters.fetch("required")
    assert_equal false, parameters.fetch("additionalProperties")
    assert_includes parameters.dig("properties", "tools", "description"), "except Agent and compose"

    assert_equal [compose, agent], Declarations.render([compose, agent]), "the render is idempotent"
    assert_nil Declarations.refusal([compose, agent])
  end

  test "an alias may omit a kernel parameter and carry its own text" do
    spawn = Declarations.render([SPAWN]).sole

    assert_equal %w[type function canonical omit description], spawn.keys
    assert_equal "Give one job to a new agent with spawn_agent; compose is for shape. " \
      "There is no wait verb: the answer reaches you later.", spawn.dig("function", "description")
    assert_equal %w[prompt lifetime wake tools], spawn.dig("function", "parameters", "properties").keys
    assert_equal ["prompt"], spawn.dig("function", "parameters", "required")
    assert_includes spawn.dig("function", "parameters", "properties", "tools", "description"),
      "except spawn_agent and compose", "inside its own text the canonical is the entry's name"
  end

  test "another text prefers the plain name when declared, else the first alias by name" do
    compose, agent, spawn = Declarations.render([COMPOSE, AGENT, SPAWN])
    assert_includes compose.dig("function", "description"), "nor\nAgent."
    assert_includes agent.dig("function", "description"), "several `Agent` calls"
    assert_includes spawn.dig("function", "description"), "with spawn_agent;"

    compose, task, agent = Declarations.render([COMPOSE, TASK, AGENT])
    assert_equal COMPOSE, compose, "the plain name is declared, so compose's bytes are the catalog's"
    assert_equal TASK, task
    assert_includes agent.dig("function", "description"), "several `Agent` calls", "the self macro is the alias's own"
  end

  test "wire strips alias facts and defaults function strictness without changing stored declarations" do
    builtin = { "type" => "web_search" }
    stored = Declarations.render([READ, FLAT, AGENT, SPAWN, builtin])
    original = stored.to_json
    wire = Declarations.wire(stored)

    assert_equal READ["function"].merge("strict" => false), wire.first.fetch("function")
    assert_equal FLAT, wire[1]
    assert_equal [%w[type function], %w[type function]], wire[2, 2].map(&:keys)
    assert_equal "Agent", wire[2].dig("function", "name")
    assert_equal [false, false], wire[2, 2].map { _1.dig("function", "strict") }
    assert_equal builtin, wire.last
    assert_equal original, stored.to_json, "wire defaults never rewrite the stored declaration"
    assert_equal [], Declarations.wire(nil)
  end

  test "wire preserves explicit strict choices in nested and flat functions" do
    [true, false].each do |strict|
      nested = READ.deep_merge("function" => { "strict" => strict })
      flat = READ.fetch("function").merge("type" => "function", "strict" => strict)
      outer = READ.merge("strict" => strict)

      assert_equal [nested, flat, outer], Declarations.wire([nested, flat, outer])
    end
  end

  test "optional reference alternatives stay optional on Responses and Codex wires" do
    schema = {
      "type" => "object",
      "properties" => {
        "prompt" => { "type" => "string", "minLength" => 1 },
        "referenced_image_paths" => { "type" => "array", "items" => { "type" => "string" }, "minItems" => 1 },
        "num_last_images_to_include" => { "type" => "integer", "minimum" => 1, "maximum" => 5 },
      },
      "required" => ["prompt"],
      "additionalProperties" => false,
    }
    function = { "name" => "render_image", "parameters" => schema }
    nested = { "type" => "function", "function" => function }
    flat = function.merge("type" => "function")
    protocols = [
      SimpleInference::Protocols::OpenAIResponses.new(base_url: "https://example.com"),
      SimpleInference::Protocols::CodexResponses.new(base_url: "https://example.com"),
      SimpleInference::Protocols::CodexResponses.new(base_url: "https://example.com", use_responses_lite: true),
    ]

    [nested, flat].each do |declaration|
      original = declaration.to_json
      tools = Declarations.wire([declaration])
      protocols.each do |protocol|
        request = protocol.compile_create(model: "test-model", input: "Draw a picture", tools: tools)
        body = JSON.parse(request.payload)
        tool = body["tools"]&.sole || body.fetch("input").first.fetch("tools").sole.fetch("tools").sole

        assert_equal false, tool["strict"], "omission lets Responses make both reference mechanisms required"
        assert_equal ["prompt"], tool.fetch("parameters").fetch("required")
        assert_equal schema, tool.fetch("parameters"), "the declaration's schema is never rewritten"
      end
      assert_equal original, declaration.to_json
    end
  end

  test "resolve_call maps an alias call onto the kernel's wire name and parameters" do
    set = Declarations.render([COMPOSE, AGENT, SPAWN, READ])
    input = { "prompt" => "p", "run_in_background" => false }

    assert_equal ["task", { "prompt" => "p", "wait" => true }, "Agent"], Declarations.resolve_call(set, "Agent", input)
    assert_equal({ "prompt" => "p", "run_in_background" => false }, input, "never mutated")
    assert_equal ["task", { "prompt" => "p", "wait" => true, "lifetime" => "turn" }, "Agent"],
      Declarations.resolve_call(set, "Agent", input.merge("lifetime" => "turn")),
      "the waiting alias leaves lifetime independent"
    assert_equal ["task", { "prompt" => "p", "lifetime" => "turn" }, "spawn_agent"],
      Declarations.resolve_call(set, "spawn_agent", { "prompt" => "p", "wait" => true, "lifetime" => "turn" }),
      "omitting immediate wait keeps the completion obligation selectable"
    assert_equal ["task", { "prompt" => "p" }, "Agent"], Declarations.resolve_call(set, "Agent", { "prompt" => "p" }),
      "an absent parameter stays absent: the kernel's default is the inverted default"
    assert_equal ["task", { "prompt" => "p", "wait" => "yes" }, "Agent"],
      Declarations.resolve_call(set, "Agent", { "prompt" => "p", "run_in_background" => "yes" }),
      "a non-boolean moves as is; the kernel's own refusal names its word (recorded residue)"
    assert_equal ["task", { "prompt" => "p" }, "spawn_agent"],
      Declarations.resolve_call(set, "spawn_agent", { "prompt" => "p", "wait" => true }), "an omitted key is dropped"
    assert_equal ["read_file", input, nil], Declarations.resolve_call(set, "read_file", input)
    assert_equal ["compose", input, nil], Declarations.resolve_call(set, "compose", input)
    assert_equal ["nope", input, nil], Declarations.resolve_call(set, "nope", input)
    assert_equal ["Agent", input, nil], Declarations.resolve_call(nil, "Agent", input), "undeclared: the name as given"
  end
end
