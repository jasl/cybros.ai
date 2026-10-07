require "test_helper"

# THE GRAMMAR of `assembly`: an ordered block list from a closed vocabulary — the three slots, the
# template's own inline text, memory, the caller's lead and tail, history exactly once, the input
# exactly once and LAST — plus root variables. `default` is the same grammar spelled as data. Every
# refusal names its JSON-pointer path.
class PromptTemplateTest < ActiveSupport::TestCase
  Template = PromptTemplate

  def blocks(*types)
    types.map { |type| type.to_s.start_with?("slot:") ? { "type" => "slot", "slot" => type.to_s.delete_prefix("slot:") } : { "type" => type.to_s } }
  end

  def refusal(value) = Template.refusal(value)

  test "DEFAULT is the fixed order spelled as data: the three slots, memory, skills, history, lead, tail, input" do
    assert_equal %w[slot:system_prompt slot:character slot:persona memory skills history lead tail input],
      Template::DEFAULT.keys, "the per-turn text rides behind history, where the next turn replays it"
    assert_nil refusal(Template::DEFAULT_TEMPLATE), "the built-in template passes its own grammar"
    assert_predicate Template::DEFAULT, :default?
    assert_equal({}, Template::DEFAULT.variables)
    assert Template::DEFAULT.places?("lead") && Template::DEFAULT.places?("tail")
    assert_predicate Template::DEFAULT, :memory?
    assert_predicate Template::DEFAULT, :skills?
  end

  test "a template parses into keyed blocks; the history block carries its numbers" do
    template = Template.parse(
      "blocks" => [
        { "type" => "slot", "slot" => "system_prompt" },
        { "type" => "inline", "role" => "user", "text" => "Scene: {{scene}}." },
        { "type" => "history", "max_entries" => 40, "budget" => { "share" => 0.6, "min_tokens" => 512 } },
        { "type" => "input" },
      ],
      "variables" => { "scene" => "an ordinary day" }
    )

    assert_equal %w[slot:system_prompt inline:1 history input], template.keys
    assert_equal 40, template.history.max_entries
    assert_equal 0.6, template.history_share
    assert_equal({ "share" => 0.6, "min_tokens" => 512 }, template.history.budget)
    assert_equal ["scene"], template.variable_names
    assert_not template.places?("tail"), "no tail block: a tail entry has nowhere to land"
    assert_not template.memory?
    assert_not template.default?
    assert_equal({ "scene" => "a rainy night" }, template.values("scene" => "a rainy night"))
    assert_equal({ "scene" => "an ordinary day" }, template.values(nil), "the default stands when the turn says nothing")
  end

  test "input exactly once and LAST; history exactly once" do
    assert_equal "/blocks/2", refusal("blocks" => blocks(:history, :input, :tail)).path,
      "a block after input is refused at its own path"
    assert_equal "/blocks/2", refusal("blocks" => blocks(:history, :input, :input)).path
    assert_equal "/blocks", refusal("blocks" => blocks(:history)).path, "no input"
    assert_equal "/blocks", refusal("blocks" => blocks(:input)).path, "no history: regenerate would re-ask without its question"
    assert_equal "/blocks/1", refusal("blocks" => blocks(:history, :history, :input)).path
  end

  test "memory, skills, lead and tail at most once; a slot at most once" do
    assert_equal "/blocks/1", refusal("blocks" => blocks(:memory, :memory, :history, :input)).path
    assert_equal "/blocks/1", refusal("blocks" => blocks(:skills, :skills, :history, :input)).path
    assert_nil refusal("blocks" => blocks(:skills, :history, :input)), "the skills block is a type of its own"
    assert_equal "/blocks/1", refusal("blocks" => blocks(:lead, :lead, :history, :input)).path
    assert_equal "/blocks/2", refusal("blocks" => blocks(:history, :tail, :tail, :input)).path
    assert_equal "/blocks/1", refusal("blocks" => blocks("slot:persona", "slot:persona", :history, :input)).path
    assert_equal "/blocks/0/slot", refusal("blocks" => [{ "type" => "slot", "slot" => "template" }] + blocks(:history, :input)).path
  end

  test "a system-role inline is admitted only in the leading run" do
    leading = { "blocks" => [
      { "type" => "slot", "slot" => "system_prompt" },
      { "type" => "inline", "role" => "system", "text" => "Be terse." },
      { "type" => "slot", "slot" => "persona" },
      { "type" => "memory" }, { "type" => "history" }, { "type" => "input" },
    ] }
    assert_nil refusal(leading)

    after_memory = { "blocks" => [
      { "type" => "slot", "slot" => "system_prompt" }, { "type" => "memory" },
      { "type" => "inline", "role" => "system", "text" => "Be terse." },
      { "type" => "history" }, { "type" => "input" },
    ] }
    assert_equal "/blocks/2/role", refusal(after_memory).path,
      "Anthropic and Gemini peel every system entry wherever it sits: a mid-list one inverts the order"

    after_user_inline = { "blocks" => [
      { "type" => "inline", "role" => "user", "text" => "Scene." },
      { "type" => "inline", "role" => "system", "text" => "Be terse." },
      { "type" => "history" }, { "type" => "input" },
    ] }
    assert_equal "/blocks/1/role", refusal(after_user_inline).path

    mid_list = { "blocks" => [
      { "type" => "history" },
      { "type" => "inline", "role" => "assistant", "text" => "Understood." },
      { "type" => "inline", "role" => "developer", "text" => "Answer briefly." },
      { "type" => "input" },
    ] }
    assert_nil refusal(mid_list), "developer, user and assistant inlines may sit anywhere before the input"
  end

  # Behind `history` a block rides the turn's PREFACE — sealed with the turn and replayed by every
  # later one. A slot there would put the durable document (a `system` entry by default, which
  # Anthropic and Gemini hoist into the top system block) into history once per turn.
  test "a slot is admitted only ahead of history" do
    behind = refusal("blocks" => blocks(:history, "slot:system_prompt", :input))
    assert_equal ["/blocks/1", "after_history"], [behind.path, behind.detail]
    assert_nil refusal("blocks" => blocks("slot:system_prompt", :memory, "slot:persona", :history, :input)),
      "ahead of history a slot may follow memory as before"
  end

  test "an inline names its role and a non-blank text, and every macro in it is a source or a declared variable" do
    base = ->(inline) { { "blocks" => [inline, { "type" => "history" }, { "type" => "input" }], "variables" => { "scene" => "x" } } }

    assert_nil refusal(base.call("type" => "inline", "role" => "user", "text" => "{{scene}} on {{ date }} with {{agent}}"))
    assert_equal "/blocks/0/text", refusal(base.call("type" => "inline", "role" => "user", "text" => "{{mood}}")).path
    assert_equal "mood", refusal(base.call("type" => "inline", "role" => "user", "text" => "{{mood}}")).detail
    assert_equal "/blocks/0/text", refusal(base.call("type" => "inline", "role" => "user", "text" => " ")).path
    assert_equal "/blocks/0/text", refusal(base.call("type" => "inline", "role" => "user", "text" => 3)).path
    assert_equal "/blocks/0/role", refusal(base.call("type" => "inline", "role" => "tool", "text" => "x")).path
    assert_equal "/blocks/0/role", refusal(base.call("type" => "inline", "text" => "x")).path
    assert_equal "/blocks/0/mood", refusal(base.call("type" => "inline", "role" => "user", "text" => "x", "mood" => "y")).path,
      "a key outside the block's own is refused at its path"
  end

  test "the root, the type word, the block count and the history numbers are closed" do
    assert_equal "/", refusal(nil).path
    assert_equal "/", refusal("blocks").path
    assert_equal "/blocks", refusal({}).path
    assert_equal "/blocks", refusal("blocks" => "history, input").path
    assert_equal "/blocks", refusal("blocks" => []).path
    assert_equal "/allocation", refusal("blocks" => blocks(:history, :input), "allocation" => {}).path
    assert_equal "/blocks/0", refusal("blocks" => ["history", { "type" => "input" }]).path
    assert_equal "/blocks/0/type", refusal("blocks" => [{ "type" => "lorebook" }, { "type" => "input" }]).path
    assert_equal "/blocks/0/foo", refusal("blocks" => [{ "type" => "memory", "foo" => 1 }, { "type" => "history" }, { "type" => "input" }]).path
    assert_equal "/blocks", refusal("blocks" => blocks(*([:memory] * 64), :history, :input)).path, "at most 64 blocks"

    history = ->(fields) { { "blocks" => [{ "type" => "history" }.merge(fields), { "type" => "input" }] } }
    assert_nil refusal(history.call("max_entries" => 200, "budget" => { "share" => 1, "min_tokens" => 0, "max_tokens" => 10 }))
    assert_equal "/blocks/0/max_entries", refusal(history.call("max_entries" => 0)).path
    assert_equal "/blocks/0/max_entries", refusal(history.call("max_entries" => 201)).path
    assert_equal "/blocks/0/max_entries", refusal(history.call("max_entries" => "5")).path
    assert_equal "/blocks/0/budget", refusal(history.call("budget" => [])).path
    assert_equal "/blocks/0/budget/priority", refusal(history.call("budget" => { "priority" => 2 })).path
    assert_equal "/blocks/0/budget/share", refusal(history.call("budget" => { "share" => 0 })).path
    assert_equal "/blocks/0/budget/share", refusal(history.call("budget" => { "share" => 1.5 })).path
    assert_equal "/blocks/0/budget/min_tokens", refusal(history.call("budget" => { "min_tokens" => -1 })).path
    assert_equal "/blocks/0/budget/max_tokens", refusal(history.call("budget" => { "max_tokens" => 1.5 })).path
    assert_equal "/blocks/0/budget/max_tokens", refusal(history.call("budget" => { "min_tokens" => 10, "max_tokens" => 5 })).path
  end

  test "variables are named [a-z][a-z0-9_]*, at most 32, never a source name, each defaulting to a string" do
    with = ->(variables) { { "blocks" => blocks(:history, :input), "variables" => variables } }

    assert_nil refusal(with.call("scene2" => "x", "a_b" => ""))
    assert_equal "/variables", refusal(with.call([])).path
    assert_equal "/variables/user", refusal(with.call("user" => "x")).path, "built-in sources are not variables"
    assert_equal "/variables/conversation_kind", refusal(with.call("conversation_kind" => "x")).path
    assert_equal "/variables/Scene", refusal(with.call("Scene" => "x")).path
    assert_equal "/variables/2fast", refusal(with.call("2fast" => "x")).path
    assert_equal "/variables/scene", refusal(with.call("scene" => 3)).path
    assert_equal "/variables/scene", refusal(with.call("scene" => nil)).path
    many = (1..33).to_h { |n| ["v#{n}", "x"] }
    assert_equal "/variables", refusal(with.call(many)).path
  end

  # The macro pattern is EXTENDED to the variable grammar: `{{scene2}}`
  # was neither substituted nor refused before (`[a-z_]+` never matched a
  # digit); now it is a name like any other, refused unknown at the door
  # and substituted when declared.
  test "a digit-bearing name is a macro: refused when unknown, substituted when declared" do
    assert_equal "scene2", Nexus::PromptMacros.unknown("Take {{scene2}}.")
    assert_nil Nexus::PromptMacros.unknown("Take {{scene2}}.", Nexus::PromptMacros::REGISTRY + ["scene2"])
    assert_equal "Take two.", Nexus::PromptMacros.render("Take {{scene2}}.", "scene2" => "two")
    assert_equal "Take {{Scene}}.", Nexus::PromptMacros.render("Take {{Scene}}.", "scene" => "two"),
      "a capital is not a name: neither matched nor refused, as before"
  end

  test "the turn's refusals: an undeclared or non-string variable, and an inline position the template lacks" do
    template = Template.parse("blocks" => blocks(:lead, :history, :input), "variables" => { "scene" => "x" })

    assert_nil template.turn_refusal(variables: { "scene" => "y" }, inline: [{ "role" => "user", "text" => "l" }])
    assert_equal :prompt_template_invalid, template.turn_refusal(variables: { "mood" => "y" }, inline: nil)
    assert_equal :prompt_template_invalid, template.turn_refusal(variables: { "scene" => 1 }, inline: nil)
    assert_equal :prompt_template_invalid, template.turn_refusal(variables: "scene=y", inline: nil)
    assert_equal :inline_position_unplaced,
      template.turn_refusal(variables: nil, inline: [{ "role" => "user", "text" => "t", "position" => "tail" }])
    assert_nil template.turn_refusal(variables: nil, inline: [{ "slot" => "persona", "text" => "P" }]),
      "a slot override is placed by slot order, never by position"
    assert_equal :prompt_template_invalid, Template::DEFAULT.turn_refusal(variables: { "scene" => "y" }, inline: nil),
      "default declares no variable: a value nothing compiles is refused, never dropped"
  end

  test "a positioned inline entry is user or developer: system and assistant are refused by name" do
    %w[system assistant].each do |role|
      assert_equal :inline_role_unplaced, Template::DEFAULT.turn_refusal(variables: nil,
        inline: [{ "role" => role, "position" => "lead", "text" => "t" }]), role
    end
    assert_nil Template::DEFAULT.turn_refusal(variables: nil, inline: [
      { "role" => "developer", "position" => "lead", "text" => "d" },
      { "role" => "user", "position" => "tail", "text" => "u" },
      { "slot" => "persona", "role" => "system", "text" => "P" },
    ]), "a slot override keeps system: it rides the leading run, never the turn's preface"
  end

  test "a profile compiles its own template only under assembly; default renders the built-in order" do
    agent = users(:agent)
    template = { "blocks" => [{ "type" => "history" }, { "type" => "input" }] }
    agent.update!(prompt_mechanism: "default", prompt_template: template)
    assert_predicate Template.for_profile(agent), :default?, "a stored template under default renders nothing"
    assert_equal [], agent.declared_variable_names

    agent.update!(prompt_mechanism: "assembly", prompt_template: template.merge("variables" => { "scene" => "x" }))
    assert_equal %w[history input], Template.for_profile(agent).keys
    assert_equal ["scene"], agent.declared_variable_names
    assert_predicate Template.for_profile(nil), :default?, "no declaring profile: the built-in order"
    assert_predicate Template.for_profile(users(:member)), :default?
  end
end
