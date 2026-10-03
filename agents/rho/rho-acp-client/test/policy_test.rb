require "test_helper"

# THE PERMISSION RELAY: a child's
# `session/request_permission` answered locally — the request's toolCall
# merged onto the tracked tool_call, THE FLOOR (`Guard.refusal` over a
# synthesized `bash`/`write` call: the nine rules and the protected roots,
# one list), then THE ROW'S POLICY (allow → the first `allow_once`, never
# `allow_always`; reject → `reject_once`; no option of the kind →
# `cancelled`); a request the floor cannot read is the policy's.
class PolicyTest < Minitest::Test
  Policy = Rho::AcpClient::Policy

  OPTIONS = [
    { "optionId" => "allow", "name" => "Allow", "kind" => "allow_once" },
    { "optionId" => "always", "name" => "Always", "kind" => "allow_always" },
    { "optionId" => "reject", "name" => "Reject", "kind" => "reject_once" },
  ].freeze

  def home = RhoTest.host.home

  def row(permissions: "allow")
    RhoAcpClientTest.row("permission", key: "fx", "permissions" => permissions)
  end

  def params(tool_call, options: OPTIONS)
    { "sessionId" => "fx-1", "toolCall" => tool_call, "options" => options }
  end

  def execute(command, id: "c1")
    { "toolCallId" => id, "kind" => "execute", "title" => "run #{command}", "rawInput" => { "command" => command } }
  end

  def edit(path, id: "c2")
    { "toolCallId" => id, "kind" => "edit", "title" => "edit #{path}", "rawInput" => { "path" => path },
      "locations" => [{ "path" => path }] }
  end

  def selected(option) = { "outcome" => { "outcome" => "selected", "optionId" => option } }

  def test_a_benign_command_takes_the_rows_allow_policy_as_allow_once
    decision = Policy.decide(params(execute("npm test")), tracked: {}, row: row, home: home)
    assert_equal selected("allow"), decision.outcome
    assert_equal "allow", decision.decision
    assert_equal "policy", decision.by
    assert_equal "execute", decision.kind
    assert_nil decision.reason
  end

  def test_the_nine_rules_refuse_by_the_floor_before_the_policy
    decision = Policy.decide(params(execute("rm -rf /")), tracked: {}, row: row, home: home)
    assert_equal selected("reject"), decision.outcome
    assert_equal "reject", decision.decision
    assert_equal "floor", decision.by
    assert_match(/recursive delete of a root directory/, decision.reason)
  end

  def test_a_path_under_a_protected_root_is_refused_by_the_floor
    decision = Policy.decide(params(edit(home.settings_path)), tracked: {}, row: row, home: home)
    assert_equal selected("reject"), decision.outcome
    assert_equal "floor", decision.by
    assert_equal "edit", decision.kind
    assert_match(/write under .* is refused: #{Regexp.escape(Rho::LoopRequest::INCUBATION)}/, decision.reason)

    outside = Policy.decide(params(edit("/tmp/anywhere/else.txt")), tracked: {}, row: row, home: home)
    assert_equal "policy", outside.by
    assert_equal "allow", outside.decision
  end

  # A command spelled as an array is joined by spaces; a command naming a
  # protected root is the floor's too (the text rule).
  def test_an_array_command_and_a_root_naming_command
    command = { "toolCallId" => "c3", "kind" => "execute", "title" => "run", "rawInput" => { "command" => ["rm", "-rf", "/"] } }
    assert_equal "floor", Policy.decide(params(command), tracked: {}, row: row, home: home).by
    # The text rule reads the root's resolved spelling (macOS's /tmp is
    # /private/tmp), as a model's command names it.
    naming = execute("cat #{Rho.spelled(home.settings_path)}")
    decision = Policy.decide(params(naming), tracked: {}, row: row, home: home)
    assert_equal "floor", decision.by
    assert_match(/bash under/, decision.reason)
  end

  def test_the_reject_policy_rejects_what_the_floor_allowed
    decision = Policy.decide(params(execute("npm test")), tracked: {}, row: row(permissions: "reject"), home: home)
    assert_equal selected("reject"), decision.outcome
    assert_equal "policy", decision.by
    assert_equal "reject", decision.decision
  end

  # AN ID-ONLY REQUEST is judged by what its `tool_call` said — the tracked
  # table — else by the policy alone.
  def test_an_id_only_request_is_judged_by_the_tracked_tool_call
    tracked = { "c9" => execute("rm -rf /", id: "c9") }
    decision = Policy.decide(params({ "toolCallId" => "c9" }), tracked: tracked, row: row, home: home)
    assert_equal "floor", decision.by
    assert_equal "reject", decision.decision

    untracked = Policy.decide(params({ "toolCallId" => "unknown" }), tracked: {}, row: row, home: home)
    assert_equal "policy", untracked.by
    assert_equal "allow", untracked.decision
    assert_nil untracked.kind
  end

  # Never `allow_always` (a grant is a person's act): with only an
  # `allow_always` and a `reject_once`, an allow is `cancelled`.
  def test_no_option_of_the_kind_answers_cancelled
    options = OPTIONS.reject { |option| option["kind"] == "allow_once" }
    decision = Policy.decide(params(execute("npm test"), options: options), tracked: {}, row: row, home: home)
    assert_equal({ "outcome" => { "outcome" => "cancelled" } }, decision.outcome)
    assert_equal "allow", decision.decision
    assert_equal "policy", decision.by

    rejecting = OPTIONS.reject { |option| option["kind"] == "reject_once" }
    refused = Policy.decide(params(execute("rm -rf /"), options: rejecting), tracked: {}, row: row, home: home)
    assert_equal({ "outcome" => { "outcome" => "cancelled" } }, refused.outcome)
    assert_equal "floor", refused.by
  end

  # The synthesized call the floor reads: a title stands in for a missing
  # command; a `title`-less, `rawInput`-less request is unreadable and
  # goes to the policy.
  def test_the_synthesis
    assert_equal [["bash", { "command" => "npm test" }]], Policy.synthesized(execute("npm test"))
    titled = { "toolCallId" => "c", "kind" => "execute", "title" => "rm -rf /" }
    assert_equal [["bash", { "command" => "rm -rf /" }]], Policy.synthesized(titled)
    assert_equal [["write", { "path" => "/a" }], ["write", { "path" => "/b" }]],
      Policy.synthesized("toolCallId" => "c", "kind" => "delete", "locations" => [{ "path" => "/a" }, { "path" => "/b" }])
    assert_equal [["write", { "path" => "/c" }]],
      Policy.synthesized("toolCallId" => "c", "kind" => "move", "rawInput" => { "path" => "/c" })
    assert_empty Policy.synthesized("toolCallId" => "c", "kind" => "read", "title" => "read x")
    assert_empty Policy.synthesized("toolCallId" => "c")
  end
end
