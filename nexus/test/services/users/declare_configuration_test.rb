require "test_helper"

# The Agent Profile's standing declaration: nine columns on the User row, written whole by one
# verb, read at each turn's materialization. Humans and the system user declare nothing.
class Users::DeclareConfigurationTest < ActiveSupport::TestCase
  BASH = {
    "type" => "function",
    "function" => { "name" => "bash", "description" => "Run a command",
                    "parameters" => { "type" => "object", "properties" => {} } },
  }.freeze
  READ = {
    "type" => "function",
    "function" => { "name" => "read", "description" => "Read a file",
                    "parameters" => { "type" => "object", "properties" => {} } },
  }.freeze

  TEMPLATE = {
    "blocks" => [
      { "type" => "slot", "slot" => "system_prompt" },
      { "type" => "inline", "role" => "user", "text" => "Scene: {{scene}}." },
      { "type" => "memory" }, { "type" => "lead" }, { "type" => "history" }, { "type" => "tail" }, { "type" => "input" },
    ],
    "variables" => { "scene" => "an ordinary day" },
  }.freeze

  setup do
    @agent = users(:agent)
  end

  def declare(user = @agent, **overrides)
    Users::DeclareConfiguration.call(user: user, **{
      tool_definitions: [READ, BASH], approval_mode: "bypass", approval_rules: nil,
      prompt_mechanism: "default", prompt_template: nil, compaction_policy: { "mode" => "kernel" },
    }.merge(overrides))
  end

  test "lifecycle hooks are a bounded whole declaration and omission clears them" do
    policy = { "stop" => { "tool" => "check_end", "timeout_ms" => 30_000, "max_continuations" => 3 } }
    assert_predicate declare(lifecycle_hooks: policy), :accepted?
    assert_equal policy, @agent.reload.lifecycle_hooks
    assert_predicate declare, :accepted?
    assert_nil @agent.reload.lifecycle_hooks
    [
      false, [], "",
      { "unknown" => policy.fetch("stop") },
      { "stop" => { "tool" => "check_end", "timeout_ms" => 0, "max_continuations" => 3 } },
      { "stop" => { "tool" => "check_end", "timeout_ms" => 30_000, "max_continuations" => 21 } },
      { "stop" => { "tool" => "compose", "timeout_ms" => 30_000, "max_continuations" => 3 } },
      { "pre_compact" => policy.fetch("stop") },
    ].each do |invalid|
      assert_equal :invalid, declare(lifecycle_hooks: invalid).outcome
      assert @agent.errors.of_kind?(:lifecycle_hooks, :invalid)
    end
  end

  # THE SEVENTH COLUMN: the profile's own model, a catalog ref the application writes and the one
  # selection check judges — refused by the resolver's word, never stored to park every addressed
  # turn.
  test "default_model declares as a catalog ref this account may run, clears when omitted, and is judged at declaration" do
    DevModelLane.ensure_enabled!(@agent.account)

    assert_equal :declared, declare(default_model: "dev/mock-text").outcome
    assert_equal "dev/mock-text", @agent.reload.default_model
    assert_equal :declared, declare.outcome
    assert_nil @agent.reload.default_model, "omitted clears, as every field of the whole replacement does"
    assert_equal :declared, declare(default_model: "").outcome
    assert_nil @agent.reload.default_model

    outcome = declare(default_model: "dev/no-such-model")
    assert_equal :invalid, outcome.outcome
    assert_match(/Default model is not a model this account may run \(unknown_model\)/,
      outcome.user.errors.full_messages.to_sentence)
    assert_equal :invalid, declare(default_model: "mock-text").outcome, "a bare word is no catalog ref"
    assert_equal :invalid, declare(default_model: "model_selector:cheap").outcome, "a selector is a policy, not the one model"
    assert_match(/unknown_provider/, declare(default_model: "nowhere/mock-text").user.errors.full_messages.to_sentence)
    assert_nil @agent.reload.default_model, "a refused ref is never stored"
  end

  # THE NINTH COLUMN: the model the kernel re-runs a step on, once, when a provider's classifier
  # declined it — judged exactly as `default_model` is, since it names one model the account runs,
  # and allowed to equal it (a run on another model falls back to the profile's own).
  test "fallback_model declares as a catalog ref judged at declaration, clears when omitted, and may equal default_model" do
    DevModelLane.ensure_enabled!(@agent.account)

    assert_equal :declared, declare(fallback_model: "dev/mock-unmetered").outcome
    assert_equal "dev/mock-unmetered", @agent.reload.fallback_model
    assert_equal :declared, declare.outcome
    assert_nil @agent.reload.fallback_model, "omitted clears, as every field of the whole replacement does"
    assert_equal :declared, declare(default_model: "dev/mock-text", fallback_model: "dev/mock-text").outcome
    assert_equal %w[dev/mock-text dev/mock-text], @agent.reload.values_at(:default_model, :fallback_model)

    outcome = declare(default_model: "dev/mock-text", fallback_model: "dev/no-such-model")
    assert_equal :invalid, outcome.outcome
    assert_match(/Fallback model is not a model this account may run \(unknown_model\)/,
      outcome.user.errors.full_messages.to_sentence)
    assert_equal :invalid, declare(fallback_model: "mock-text").outcome, "a bare word is no catalog ref"
    assert_equal :invalid, declare(fallback_model: "model_selector:cheap").outcome, "a selector is a policy, not the one model"
    both = declare(default_model: "nowhere/a", fallback_model: "nowhere/b")
    assert both.user.errors.added?(:default_model, :not_authorized, refusal: :unknown_provider)
    assert both.user.errors.added?(:fallback_model, :not_authorized, refusal: :unknown_provider), "both refusals are named"
    assert_equal %w[dev/mock-text dev/mock-text], @agent.reload.values_at(:default_model, :fallback_model),
      "a refused ref is never stored"
  end

  test "an unchanged default model is retained while new refs still pass the current provider policy" do
    DevModelLane.ensure_enabled!(@agent.account)
    assert_equal :declared, declare(default_model: "dev/mock-text").outcome
    policy = ModelProviderPolicy.find_by!(account: @agent.account, provider_id: "dev")
    ModelProviders::DisableLane.call(
      account: @agent.account, provider_id: policy.provider_id, expected_lock_version: policy.lock_version
    )

    assert_equal :declared, declare(default_model: "dev/mock-text", approval_mode: "ask").outcome
    assert_equal "ask", @agent.reload.approval_mode

    outcome = declare(default_model: "dev/mock-priced", approval_mode: nil)
    assert_equal :invalid, outcome.outcome
    assert outcome.user.errors.added?(:default_model, :not_authorized, refusal: :provider_disabled)
    assert outcome.user.errors.of_kind?(:approval_mode, :blank), "the model's own errors accompany the resolver refusal"
    assert_equal "dev/mock-text", @agent.reload.default_model
    assert_equal "ask", @agent.approval_mode, "a refused declaration writes none of its fields"
  end

  test "an agent profile declares its configuration whole, canonical by tool name" do
    outcome = declare

    assert_equal :declared, outcome.outcome
    assert_predicate outcome, :accepted?
    @agent.reload
    assert_equal %w[bash read], @agent.tool_definitions.map { |entry| entry.dig("function", "name") },
      "the set heads every cached prefix, so it is stored sorted by name"
    assert_equal "bypass", @agent.approval_mode
    assert_equal "default", @agent.prompt_mechanism
    assert_nil @agent.prompt_template
    assert_equal({ "mode" => "kernel" }, @agent.compaction_policy)
  end

  test "a second declaration replaces the whole set; an empty list is no tools" do
    declare
    outcome = declare(tool_definitions: [], compaction_policy: nil, prompt_template: TEMPLATE)

    assert_predicate outcome, :accepted?
    @agent.reload
    assert_nil @agent.tool_definitions
    assert_nil @agent.compaction_policy
    assert_equal TEMPLATE, @agent.prompt_template, "a template may stand on a default profile; nothing reads it there"
  end

  # The three approval modes declare and read back; the rule list is the fifth column,
  # whole-replaced with the rest and validated through the one evaluator the stage reads.
  test "ask and rules declare and read back, with the rule list beside them" do
    rules = [{ "tool" => "bash", "path" => "command", "match" => "*rm -rf /*", "verdict" => "deny" },
             { "tool" => "memory_*|ask|task|compose", "verdict" => "allow" }]
    %w[ask rules].each do |mode|
      outcome = declare(approval_mode: mode, approval_rules: rules)

      assert_predicate outcome, :accepted?
      assert_equal mode, @agent.reload.approval_mode
      assert_equal rules, @agent.approval_rules
    end

    assert_predicate declare(approval_rules: []), :accepted?
    assert_nil @agent.reload.approval_rules, "an empty list is no rules"
  end

  test "approval_rules validates through the one evaluator" do
    outcome = declare(approval_rules: [{ "tool" => "bash", "verdict" => "never" }])
    assert_equal :invalid, outcome.outcome
    assert outcome.user.errors.of_kind?(:approval_rules, :verdict_invalid)

    outcome = declare(approval_rules: { "tool" => "bash" })
    assert_equal :invalid, outcome.outcome
    assert outcome.user.errors.of_kind?(:approval_rules, :invalid)
    assert_nil @agent.reload.approval_rules
  end

  # NO SILENT DEFAULT: a profile that serves tools says how they are approved; a tool-less profile
  # has nothing to approve.
  test "tools without an approval mode are refused; a tool-less profile may leave it nil" do
    outcome = declare(approval_mode: nil)
    assert_equal :invalid, outcome.outcome
    assert outcome.user.errors.of_kind?(:approval_mode, :blank)
    assert_nil @agent.reload.tool_definitions, "nothing was written"

    assert_predicate declare(tool_definitions: [], approval_mode: nil), :accepted?
    assert_nil @agent.reload.approval_mode
  end

  # `assembly` declares with its template; the invariant "assembly ⇒ a template" is the row's own
  # presence rule — no cross-row check, no drain-time park for a template that vanished (it cannot).
  test "the assembly mechanism declares with a template and is invalid without one" do
    outcome = declare(prompt_mechanism: "assembly", prompt_template: TEMPLATE)
    assert_equal :declared, outcome.outcome
    @agent.reload
    assert_equal "assembly", @agent.prompt_mechanism
    assert_equal TEMPLATE, @agent.prompt_template

    outcome = declare(prompt_mechanism: "assembly", prompt_template: nil)
    assert_equal :invalid, outcome.outcome
    assert outcome.user.errors.of_kind?(:prompt_template, :blank)
    assert_equal "assembly", @agent.reload.prompt_mechanism, "nothing was written"
    assert_equal TEMPLATE, @agent.prompt_template
  end

  test "a template outside the grammar is invalid, naming the path" do
    outcome = declare(prompt_mechanism: "assembly",
      prompt_template: { "blocks" => [{ "type" => "history" }, { "type" => "input" }, { "type" => "tail" }] })
    assert_equal :invalid, outcome.outcome
    assert outcome.user.errors.of_kind?(:prompt_template, :invalid_template)
    assert_includes outcome.user.errors.full_messages.join, "/blocks/2"

    assert_equal :invalid, declare(prompt_mechanism: "default", prompt_template: ["history"]).outcome
    assert @agent.errors.of_kind?(:prompt_template, :invalid), "a list is not a template, under any mechanism"
    assert_equal :invalid, declare(prompt_mechanism: "default", prompt_template: { "blocks" => "x" }).outcome
    assert @agent.errors.of_kind?(:prompt_template, :invalid_template)
  end

  test "a re-declaration that drops a variable the profile's own system_prompt still uses is refused naming the slot" do
    assert_predicate declare(prompt_mechanism: "assembly", prompt_template: TEMPLATE), :accepted?
    written = PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt",
      content: "Today's scene is {{scene}} with {{user}}.")
    assert_predicate written, :written?, written.outcome.inspect

    dropped = { "blocks" => TEMPLATE.fetch("blocks").reject { |block| block["type"] == "inline" } }
    outcome = declare(prompt_mechanism: "assembly", prompt_template: dropped)
    assert_equal :invalid, outcome.outcome
    assert outcome.user.errors.of_kind?(:prompt_template, :variable_in_use)
    assert_match(/scene.*system_prompt/, outcome.user.errors.full_messages.join)

    outcome = declare(prompt_mechanism: "default", prompt_template: nil)
    assert_equal :invalid, outcome.outcome, "under default the four sources are the whole registry"
    assert outcome.user.errors.of_kind?(:prompt_template, :variable_in_use)

    assert_predicate declare(prompt_mechanism: "assembly",
      prompt_template: TEMPLATE.merge("variables" => { "scene" => "dusk", "mood" => "calm" })), :accepted?
  end

  test "a word outside either vocabulary is invalid rather than unavailable" do
    outcome = declare(approval_mode: "always")
    assert_equal :invalid, outcome.outcome
    assert outcome.user.errors.of_kind?(:approval_mode, :inclusion)

    outcome = declare(prompt_mechanism: "template")
    assert_equal :invalid, outcome.outcome
    assert outcome.user.errors.of_kind?(:prompt_mechanism, :inclusion)
  end

  test "humans and the system user carry no configuration" do
    [users(:member), users(:system)].each do |user|
      assert_equal :not_agent_profile, declare(user).outcome

      user.approval_mode = "bypass"
      user.approval_rules = [{ "tool" => "bash", "verdict" => "deny" }]
      user.tool_definitions = [BASH]
      assert_not user.valid?
      assert user.errors.of_kind?(:approval_mode, :present)
      assert user.errors.of_kind?(:approval_rules, :present)
      assert user.errors.of_kind?(:tool_definitions, :present)
    end
  end

  test "the tool set is a non-empty list of declarations under the envelope bound" do
    assert_equal :invalid, declare(tool_definitions: ["bash"]).outcome
    assert @agent.errors.of_kind?(:tool_definitions, :invalid)

    assert_equal :invalid, declare(tool_definitions: { "name" => "bash" }).outcome
    assert @agent.errors.of_kind?(:tool_definitions, :invalid)

    oversized = BASH.merge("function" => BASH.fetch("function").merge("description" => "x" * 70_000))
    assert_equal :invalid, declare(tool_definitions: [oversized]).outcome
    assert @agent.errors.of_kind?(:tool_definitions, :content_too_large)
  end

  # The kernel's name space is checked exactly as the task compiler checks
  # it: a kernel tool in other bytes tells the model one thing while the
  # kernel does another.
  test "the tool set obeys the kernel-name rule the task compiler applies" do
    paraphrased = BASH.merge("function" => BASH.fetch("function").merge("name" => "compose"))
    assert_equal :invalid, declare(tool_definitions: [paraphrased]).outcome
    assert @agent.errors.of_kind?(:tool_definitions, :kernel_tool_redefined)

    compose = Nexus::ToolRegistry.function_definition("nexus.graph.compose")
    assert_predicate declare(tool_definitions: [BASH, compose]), :accepted?
    assert_equal %w[bash compose],
      @agent.reload.tool_definitions.map { |entry| entry.dig("function", "name") }
  end

  # ── the alias: the store holds the profile's RENDER ──

  AGENT = LoopLaneTestHelper::AGENT_ALIAS
  COMPOSE = Nexus::ToolRegistry.function_definition("nexus.graph.compose")

  test "an alias is stored as the profile's render and read back with its facts" do
    assert_predicate declare(tool_definitions: [READ, AGENT]), :accepted?

    agent = @agent.reload.tool_definitions.find { |entry| entry.dig("function", "name") == "Agent" }
    assert_equal %w[canonical function params type], agent.keys.sort, "jsonb keeps no key order"
    assert_equal "nexus.graph.task", agent["canonical"]
    assert_equal AGENT["params"], agent["params"]
    assert_includes agent.dig("function", "description"), "several `Agent` calls in ONE message"
    assert_equal %w[lifetime prompt run_in_background tools wake], agent.dig("function", "parameters", "properties").keys.sort,
      "the kernel's parameters under the alias's names (jsonb keeps no key order; the render does)"
    assert_equal true, agent.dig("function", "parameters", "properties", "run_in_background", "default")
    assert_equal %w[Agent read], @agent.tool_definitions.map { |entry| entry.dig("function", "name") },
      "canonical by name among the rest"
  end

  test "each alias refusal word lands on the door" do
    {
      "alias_canonical_unknown" => AGENT.merge("canonical" => "rho.fs.read"),
      "alias_name_reserved" => { "name" => "task", "canonical" => "nexus.graph.compose" },
      "alias_param_unknown" => AGENT.merge("params" => { "bg" => { "maps_to" => "background" } }),
      "alias_invert_needs_boolean" =>
        AGENT.merge("params" => { "text" => { "maps_to" => "prompt", "invert" => true, "description" => "x" } }),
      "alias_param_description_required" =>
        AGENT.merge("params" => { "run_in_background" => { "maps_to" => "wait", "invert" => true } }),
    }.each do |word, entry|
      assert_equal :invalid, declare(tool_definitions: [READ, entry]).outcome, word
      assert @agent.errors.of_kind?(:tool_definitions, word.to_sym), word
    end
    assert_equal :invalid, declare(tool_definitions: [READ, READ]).outcome
    assert @agent.errors.of_kind?(:tool_definitions, :duplicate_tool_name)
    assert_equal :invalid, declare(tool_definitions: [AGENT, BASH.merge("function" => { "name" => "Agent" })]).outcome
    assert @agent.errors.of_kind?(:tool_definitions, :duplicate_tool_name), "an alias and a runner tool on one name"
  end

  test "a plain kernel entry beside an alias is stored re-rendered, and the stored bytes re-declare" do
    assert_predicate declare(tool_definitions: [COMPOSE, AGENT]), :accepted?
    stored = @agent.reload.tool_definitions
    compose = stored.find { |entry| entry.dig("function", "name") == "compose" }
    assert_includes compose.dig("function", "description"), "you need neither compose nor\nAgent."
    refute_equal COMPOSE, compose, "compose's text spells the set's name for task"

    assert_predicate declare(tool_definitions: stored), :accepted?, "the render validates as itself"
    assert_equal stored, @agent.reload.tool_definitions, "and is the same bytes"
  end

  test "the compaction policy is exactly the shape a round's compaction takes" do
    assert_equal :invalid, declare(compaction_policy: { "mode" => "sometimes" }).outcome
    assert @agent.errors.of_kind?(:compaction_policy, :invalid)

    assert_equal :invalid, declare(compaction_policy: { "mode" => "delegate" }).outcome
    assert @agent.errors.of_kind?(:compaction_policy, :invalid)

    assert_equal :invalid, declare(compaction_policy: ["kernel"]).outcome
    assert @agent.errors.of_kind?(:compaction_policy, :invalid)

    assert_predicate declare(compaction_policy: { "mode" => "delegate", "tool_name" => "summarize" }), :accepted?
    assert_predicate declare(compaction_policy: { "mode" => "off" }), :accepted?
  end

  test "the template is bounded like a prompt document" do
    outcome = declare(prompt_template: TEMPLATE.merge("variables" => { "scene" => "x" * 66_000 }))

    assert_equal :invalid, outcome.outcome
    assert @agent.errors.of_kind?(:prompt_template, Nexus::SizeBounds::REJECTION)
  end
end
