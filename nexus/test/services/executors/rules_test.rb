require "test_helper"

# THE ONE RULE MODEL: a flat list of triples over the wire `tool_name` and a dotted path into
# `tool_input`, evaluated with codex/claude-code strictness — deny beats ask beats allow — and read
# through the agent's OWN path, so the kernel never learns what `bash` is. Anchored globs, `*` and
# `?` alone special; a scalar array joins by one space; every other non-string never matches — and
# under `bypass` a non-match is a grant, which is why a typo in a tool name must never grant.
class Executors::RulesTest < ActiveSupport::TestCase
  Rules = Executors::Rules

  def verdict(rules, tool_name: "bash", tool_input: { "command" => "ls -la" }, origin: "model")
    Rules.verdict(rules, tool_name: tool_name, tool_input: tool_input, origin: origin)
  end

  def deny(**over) = { "tool" => "bash", "verdict" => "deny" }.merge(over.transform_keys(&:to_s))
  def allow(**over) = { "tool" => "bash", "verdict" => "allow" }.merge(over.transform_keys(&:to_s))
  def ask(**over) = { "tool" => "bash", "verdict" => "ask" }.merge(over.transform_keys(&:to_s))

  test "nil and an empty list are no rules: nothing matches" do
    assert_nil verdict(nil).word
    assert_nil verdict([]).word
  end

  test "deny beats a later allow, ask beats allow, and the first deny's reason rides" do
    assert_equal "deny", verdict([allow, deny]).word
    assert_equal "ask", verdict([allow, ask]).word
    assert_equal "allow", verdict([allow]).word

    rules = [deny(reason: "first"), allow, deny(reason: "second")]
    decided = verdict(rules)
    assert_predicate decided, :deny?
    assert_equal "first", decided.reason
    assert_nil verdict([ask, allow]).reason, "only a denial carries a reason"
  end

  test "match is anchored: a leading star is what lets a fragment match" do
    forced = { "command" => "echo git push --force" }
    assert_nil verdict([deny(path: "command", match: "git push*--force*")], tool_input: forced).word,
      "anchored: the pattern must cover the whole command"
    assert_equal "deny", verdict([deny(path: "command", match: "*git push*--force*")], tool_input: forced).word
    assert_equal "deny", verdict([deny(path: "command", match: "git push*--force*")],
      tool_input: { "command" => "git push origin main --force-with-lease" }).word
  end

  test "? is one byte, * crosses a newline, and every other byte is literal" do
    assert_equal "deny", verdict([deny(path: "command", match: "rm -r?")], tool_input: { "command" => "rm -rf" }).word
    assert_nil verdict([deny(path: "command", match: "rm -r?")], tool_input: { "command" => "rm -rff" }).word
    assert_equal "deny", verdict([deny(path: "command", match: "*rm -rf /*")],
      tool_input: { "command" => "echo hi\nrm -rf /tmp/x" }).word
    assert_nil verdict([deny(path: "command", match: "a.b")], tool_input: { "command" => "axb" }).word,
      "a dot is a dot, never a regex wildcard"
    assert_equal "deny", verdict([deny(path: "command", match: "a.b")], tool_input: { "command" => "a.b" }).word
    assert_nil verdict([deny(path: "command", match: "(ls)")], tool_input: { "command" => "ls" }).word
  end

  test "the path is a dotted walk into tool_input: keys, integer indices, and nothing else" do
    input = { "command" => "ls", "edits" => [{ "path" => ".env" }, { "path" => "README.md" }], "opts" => { "a" => 1 } }
    assert_equal "deny", verdict([deny(path: "edits.0.path", match: "*.env")], tool_input: input).word
    assert_nil verdict([deny(path: "edits.1.path", match: "*.env")], tool_input: input).word
    assert_nil verdict([deny(path: "missing", match: "*")], tool_input: input).word, "a missing key never matches"
    assert_nil verdict([deny(path: "opts", match: "*")], tool_input: input).word, "a Hash at the leaf never matches"
    assert_nil verdict([deny(path: "opts.a", match: "*")], tool_input: input).word, "an Integer never matches"
    assert_nil verdict([deny(path: "edits.x.path", match: "*")], tool_input: input).word,
      "a non-integer segment over an Array walks nowhere"
    assert_nil verdict([deny(path: "command.0", match: "*")], tool_input: input).word,
      "a String is a leaf, not a container"
    assert_nil verdict([deny(path: "command", match: "*")], tool_input: nil).word
    assert_nil verdict([deny(path: "command", match: "*")], tool_input: "ls").word
  end

  test "a scalar array joins by one space; a nested array or a scalar alone never matches" do
    input = { "argv" => ["rm", "-rf", "/"], "nested" => [["rm"], "-rf"], "count" => 3, "flag" => true }
    assert_equal "deny", verdict([deny(path: "argv", match: "*rm -rf /*")], tool_input: input).word
    assert_equal "deny", verdict([deny(path: "argv", match: "rm -rf /")], tool_input: input).word
    assert_nil verdict([deny(path: "nested", match: "*")], tool_input: input).word
    assert_nil verdict([deny(path: "count", match: "*")], tool_input: input).word
    assert_nil verdict([deny(path: "flag", match: "*")], tool_input: input).word
    assert_equal "deny", verdict([deny(path: "mixed", match: "a 1 true")],
      tool_input: { "mixed" => ["a", 1, true] }).word, "numbers and booleans inside an array join as text"
  end

  test "a rule with no path matches the tool as a whole; a path without a match needs text there" do
    assert_equal "ask", verdict([ask], tool_input: nil).word
    assert_equal "ask", verdict([ask(path: "command")], tool_input: { "command" => "ls" }).word
    assert_nil verdict([ask(path: "command")], tool_input: { "other" => "ls" }).word
  end

  test "tool alternatives and tool globs match the wire name whole" do
    rule = deny(tool: "write|edit", path: "path", match: "*.env")
    input = { "path" => "config/.env" }
    assert_equal "deny", verdict([rule], tool_name: "write", tool_input: input).word
    assert_equal "deny", verdict([rule], tool_name: "edit", tool_input: input).word
    assert_nil verdict([rule], tool_name: "editor", tool_input: input).word, "anchored on the name too"
    assert_equal "allow", verdict([allow(tool: "memory_*|ask|task|compose")], tool_name: "memory_read").word
    assert_equal "allow", verdict([allow(tool: "memory_*|ask|task|compose")], tool_name: "compose").word
    assert_nil verdict([allow(tool: "memory_*|ask|task|compose")], tool_name: "bash").word
  end

  test "a rule addresses model rows unless it names an origin" do
    assert_equal "ask", verdict([ask], origin: "model").word
    assert_nil verdict([ask], origin: "author").word, "an authored row is out of a rule's reach by default"
    assert_nil verdict([ask], origin: "kernel").word
    assert_equal "ask", verdict([ask(origin: "author")], origin: "author").word
    assert_nil verdict([ask(origin: "author")], origin: "model").word
  end

  test "a typo never grants: a rule naming bsh matches nothing" do
    assert_nil verdict([allow(tool: "bsh")]).word
  end

  # ── The declaration-time refusals ──────────────────────────────────────

  def refusal(value) = Rules.refusal(value)&.code

  test "nil and an empty list are accepted; anything but a list of objects is refused by shape" do
    assert_nil refusal(nil)
    assert_nil refusal([])
    assert_nil refusal([deny, allow(tool: "memory_*", origin: "kernel", reason: "kernel tools")])
    assert_equal :not_a_list, refusal({ "tool" => "bash" })
    assert_equal :not_a_list, refusal("bash")
    assert_equal :not_an_object, refusal(["bash"])
    assert_equal :not_an_object, refusal([nil])
  end

  test "the six keys are the whole grammar and each is typed" do
    seventh = Rules.refusal([deny(scope: "workspace")])
    assert_equal :unknown_key, seventh.code
    assert_equal "scope", seventh.key
    assert_equal :tool_required, refusal([{ "verdict" => "deny" }])
    assert_equal :tool_required, refusal([deny(tool: "")])
    assert_equal :tool_required, refusal([deny(tool: ["bash"])])
    assert_equal :tool_required, refusal([deny(tool: "bash|")])
    assert_equal :verdict_invalid, refusal([{ "tool" => "bash" }])
    assert_equal :verdict_invalid, refusal([deny(verdict: "never")])
    assert_equal :origin_invalid, refusal([deny(origin: "person")])
    assert_equal :match_without_path, refusal([deny(match: "*")])
    assert_equal :path_invalid, refusal([deny(path: "command..0", match: "*")])
    assert_equal :path_invalid, refusal([deny(path: "", match: "*")])
    assert_equal :path_invalid, refusal([deny(path: ["command"], match: "*")])
    assert_equal :glob_invalid, refusal([deny(path: "command", match: 3)])
    assert_equal :glob_invalid, refusal([deny(path: "command", match: "\xFF".b)])
    assert_equal :glob_invalid, refusal([deny(tool: "\xFF".b)])
    assert_equal :reason_invalid, refusal([deny(reason: ["why"])])
  end

  # The two validated homes of a rule list: the profile's fifth column and
  # the standalone loop's shell, both under the envelope bound.
  test "the validator names the refusal on the profile and on the loop, and the 64 KiB bound holds" do
    agent = users(:agent)
    agent.approval_rules = [deny(scope: "x")]
    assert_not agent.valid?
    assert agent.errors.of_kind?(:approval_rules, :unknown_key)
    assert_match(/scope/, agent.errors.full_messages.to_sentence)

    agent.approval_rules = "bash"
    assert_not agent.valid?
    assert agent.errors.of_kind?(:approval_rules, :invalid), "the shape validator refuses a non-list first"

    agent.approval_rules = [deny(reason: "x" * 70_000)]
    assert_not agent.valid?
    assert agent.errors.of_kind?(:approval_rules, :content_too_large)

    agent.approval_rules = [deny(reason: "fine")]
    agent.valid?
    assert_empty agent.errors[:approval_rules]

    agent_loop = AgentLoop.new(workspace: workspaces(:shared), creating_user: users(:member),
      approval_mode: "rules", approval_rules: [deny(verdict: "never")])
    assert_not agent_loop.valid?
    assert agent_loop.errors.of_kind?(:approval_rules, :verdict_invalid)
    agent_loop.approval_rules = nil
    agent_loop.valid?
    assert_empty agent_loop.errors[:approval_rules]
  end
end
