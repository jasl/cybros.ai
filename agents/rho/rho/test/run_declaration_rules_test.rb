require_relative "run_declaration_test"

class RunDeclarationTest
  def test_many_remote_runners_keep_the_complete_wire_policy_at_the_same_size
    home = Rho::Home.resolve(base_url: "https://nexus.example",
      root: "/private/var/folders/_6/7vgpkxd14klg0lpvxyh5nk2h0000gn/T/rho-telegram-e2e20261006-56370-ctaq3p/home")
    host = RhoTest.host.with(home: home, config: Rho::Config.from_hash({ "mode" => "agent" }))
    agent = Rho::Extensions.load(host: host, extensions: Rho::Extensions.defaults_for("agent"),
      gems: Rho::Extensions::TOOL_GEMS).registry
    full = Rho::Extensions.load(host: RhoTest.host, gems: Rho::Extensions::TOOL_GEMS).registry
    served = Rho::RunDeclaration.announcement(registry: full.serving(:runner))
    mcp = NexusDoubles.served_tool("mcp__files__save").merge("input_schema" => {
      "type" => "object", "properties" => { "path" => { "type" => "string" } },
    })
    served += [mcp]
    runners = 16.times.map { |index| format("019a0000-0000-7000-8000-%012d", index + 1) }
    documents = runners.map { |id| RunnerDocument.new(public_id: id, served_tools: served) }
    roots = Rho.protected_roots(home)
    baseline = Rho::RunDeclaration.declaration(registry: agent, remote: documents.first(1), roots: roots,
      runner_executor_public_ids: runners.first(1))
    declared = Rho::RunDeclaration.declaration(registry: agent, remote: documents, roots: roots, runner_executor_public_ids: runners)
    rules = declared.fetch(:approval_rules)

    assert_equal baseline.fetch(:approval_rules), rules,
      "more candidates do not duplicate the same served-name policy"
    assert_equal baseline.fetch(:tool_definitions), declared.fetch(:tool_definitions),
      "candidate schemas never expand Agent-authored tool definitions"
    assert_equal runners, declared.fetch(:runner_executor_public_ids)
    assert_equal JSON.generate(baseline.fetch(:approval_rules)).bytesize, JSON.generate(rules).bytesize
    assert_operator JSON.generate(rules).bytesize, :<=, 65_536,
      "the Profile envelope must fit sixteen complete Runners and long protected paths"
    assert_equal roots.length, rules.count { |rule| rule.fetch("tool") == "mcp__files__save" },
      "identical MCP denies are declared once for each protected root"
    refute declared.fetch(:tool_definitions).any? { |entry| entry.key?("route") }
    assert_equal ["allow", nil], wire_verdict(rules, "read")
    assert_equal ["allow", nil], wire_verdict(rules, "runners_list")
    assert_equal ["deny", "recursive delete of a root directory"], wire_verdict(rules, "bash", { "command" => "rm -rf /" })
    assert_equal ["deny", Rho::RunDeclaration::INCUBATION], wire_verdict(rules, "write", { "path" => roots.first })
    assert_equal ["deny", Rho::RunDeclaration::INCUBATION], wire_verdict(rules, "mcp__files__save", { "path" => roots.first })
    assert_equal [nil, nil], wire_verdict(rules, "write", { "path" => "/project/result.txt" })
  end

  def test_exact_rule_deduplication_preserves_origins_order_and_first_denial_reason
    grants = [
      { "tool" => "bash", "path" => "command", "match" => "danger*", "verdict" => "deny", "reason" => "first" },
      { "tool" => "start_process", "path" => "command", "match" => "danger*", "verdict" => "deny", "reason" => "second" },
      { "tool" => "start_process", "path" => "command", "match" => "danger*", "verdict" => "deny", "reason" => "first" },
      { "tool" => "bash|start_process", "path" => "command", "match" => "check*", "verdict" => "ask" },
      { "tool" => "read|bash|start_process", "verdict" => "allow" },
      { "tool" => "bash", "verdict" => "ask", "origin" => "author" },
    ]
    source = Rho::RunDeclaration::APPROVAL_RULES + grants
    rules = Rho::RunDeclaration.approval_rules(grants: grants + [grants.first, grants.last])
    assert_equal source, rules, "exact duplicates disappear at their later position; distinct clauses remain"
    %w[read bash start_process].each do |name|
      %w[model author].product(%w[dangerous check safe]).each do |origin, command|
        assert_equal wire_verdict(source, name, { "command" => command }, origin: origin),
          wire_verdict(rules, name, { "command" => command }, origin: origin)
      end
    end
    assert_equal ["deny", "second"],
      wire_verdict(rules, "start_process", { "command" => "dangerous" })
    assert_equal ["ask", nil], wire_verdict(rules, "bash", origin: "author")
    assert_equal [nil, nil], wire_verdict(rules, "unrelated")
  end

  # The existing glob mirror judges the same flat-path rule fixtures as the
  # kernel's resolved wire-name boundary: all matching rules participate,
  # with the first denial's reason. End-to-end tests own alias resolution.
  def wire_verdict(rules, name, input = {}, origin: "model")
    matching = rules.select do |rule|
      (rule["origin"] || "model") == origin && rule.fetch("tool").split("|").any? { |pattern| glob(pattern).match?(name) } &&
        (!rule.key?("path") || (input[rule.fetch("path")] && glob(rule.fetch("match")).match?(input.fetch(rule.fetch("path")))))
    end
    denial = matching.find { |rule| rule.fetch("verdict") == "deny" }
    return ["deny", denial["reason"]] if denial

    [matching.any? { |rule| rule.fetch("verdict") == "ask" } ? "ask" : ("allow" unless matching.empty?), nil]
  end
end
