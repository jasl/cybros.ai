require "minitest/autorun"
require "active_support/all"
require_relative "../../nexus/app/services/executors/rules"
require_relative "../support/mcp_fixture/declarations"

# THE DERIVED DENIES ARE ADMITTED BY THE KERNEL'S GRAMMAR: rho derives, from each `mcp__` entry's
# announced schema, one deny rule per text-shaped top-level property per protected root — and the
# kernel's `declare_configuration` is all-or-nothing, so ONE rule its grammar refuses would cost the
# daemon EVERY tool. The coupling lives where both trees load — here, never in either suite: every
# rule derived from the fixture server's declarations passes `Executors::Rules.rule_refusal`, a
# property whose name is not one valid path segment (`file.path`) yields no rule and is listed as
# skipped, and the whole list passes `refusal`.
class KernelRuleGrammarTest < Minitest::Test
  RHO_RUNNER_LIB = File.expand_path("../../agents/rho/rho-runner/lib", __dir__)
  RHO_LIB = File.expand_path("../../agents/rho/rho/lib", __dir__)
  ROOTS = ["/opt/rho", "/home/a/.rho"].freeze

  def setup
    $LOAD_PATH.unshift(RHO_RUNNER_LIB) unless $LOAD_PATH.include?(RHO_RUNNER_LIB)
    $LOAD_PATH.unshift(RHO_LIB) unless $LOAD_PATH.include?(RHO_LIB)
    require "rho"
    # `rule_refusal` reads `AgentLoopNode::AUTHORS` only for a rule naming
    # an `origin`; the request list does, so the model's constant stands in.
    Object.const_set(:AgentLoopNode, Module.new { const_set(:AUTHORS, %w[model author kernel]) }) unless defined?(AgentLoopNode)
  end

  # The announced entries as discovery hands them back: the public name
  # and the verbatim schema.
  def entries
    E2E::McpFixture.announced("fx", E2E::McpFixture::TOOLS.map { |t| t.fetch("name") }).map do |tool|
      { "name" => tool.fetch("name"), "effect_profile" => {}, "input_schema" => tool.fetch("inputSchema") }
    end
  end

  def test_every_derived_rule_is_admitted_and_the_dotted_property_is_skipped
    rules = Rho::LoopRequest.self_modification_rules(ROOTS, entries: entries)
    derived = rules.select { |rule| rule.fetch("tool").start_with?("mcp__") }
    refute_empty derived
    derived.each do |rule|
      assert_nil Executors::Rules.rule_refusal(rule), "the kernel would refuse #{rule.inspect}"
      assert Executors::Rules::Path.valid?(rule.fetch("path"))
    end
    assert_equal %w[echo.text lookup.key paths.paths write.text].sort,
      derived.map { |rule| "#{rule.fetch("tool").delete_prefix("mcp__fx__")}.#{rule.fetch("path")}" }.uniq.sort
    refute(derived.any? { |rule| rule.fetch("path") == "file.path" }, "a dotted property never becomes a rule")
    lookup = entries.find { |entry| entry.fetch("name") == "mcp__fx__lookup" }
    assert_equal ["file.path"], Rho::LoopRequest.deny_properties(lookup).skipped
    assert_equal ["key"], Rho::LoopRequest.deny_properties(lookup).derivable
    assert_equal ROOTS.length * 4, derived.length, "one rule per text property per root"
  end

  def test_the_whole_declared_list_passes_the_kernels_refusal_under_both_origins
    assert_nil Executors::Rules.refusal(Rho::LoopRequest.approval_rules(roots: ROOTS, entries: entries))
    assert_nil Executors::Rules.refusal(Rho::LoopRequest.request_rules(roots: ROOTS, entries: entries))
  end

  # The rule binds the way `bash`'s does: a text naming the root, or an
  # array of paths one of which names it, is denied; a sibling path is not.
  def test_a_derived_rule_matches_the_text_the_way_the_kernel_reads_it
    rules = Rho::LoopRequest.self_modification_rules(["/opt/rho"], entries: entries)
    verdict = ->(tool, input) { Executors::Rules.verdict(rules, tool_name: tool, tool_input: input, origin: "model") }
    assert_predicate verdict.call("mcp__fx__echo", { "text" => "please edit /opt/rho/settings.json" }), :deny?
    assert_equal Rho::LoopRequest::INCUBATION, verdict.call("mcp__fx__echo", { "text" => "cat /opt/rho/x" }).reason
    assert_predicate verdict.call("mcp__fx__paths", { "paths" => ["/tmp/a", "/opt/rho/lib"] }), :deny?
    assert_nil verdict.call("mcp__fx__echo", { "text" => "elsewhere" }).word
    assert_nil verdict.call("mcp__fx__lookup", { "key" => "k", "file.path" => "/opt/rho/x" }).word,
      "the dotted property is the recorded hole: nothing derives from it"
  end
end
