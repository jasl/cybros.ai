require "test_helper"
require "support/nexus_doubles"
require "support/daemon_harness"

# THE SESSION-SCOPED APPROVAL GRANT, DAEMON SIDE: `POST /runs/approve`
# with `always`/`match` reads the held row, derives ONE allow rule before
# anything moves (every derivation refusal is 400 `malformed_body` with its
# sentence), approves through the kernel's one door, then — under the
# declaring gate — adds the grant and RE-DECLARES the profile: the rule
# list ends with the rule, the tool bytes do not move, `already` on a
# shape held, a kernel refusal revokes the grant it just added and answers
# `refused`. The grants live in `Bindings` alone, ride the standalone
# shell's list, are listed by `GET /rules`, and are re-declared away on
# the daemon's clean stop.
class DaemonGrantsTest < Minitest::Test
  include RhoTest::DaemonHarness

  HELD = {
    "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "needs_approval", "tool_name" => "bash",
    "tool_input" => { "command" => "npm test" }, "on_failure" => "absorb", "visibility" => "visible",
    "created_at" => "2026-09-15T00:00:00Z",
  }.freeze
  EXACT = { "tool" => "bash", "path" => "command", "match" => "npm test", "verdict" => "allow" }.freeze
  PREFIX = { "tool" => "bash", "path" => "command", "match" => "npm *", "verdict" => "allow" }.freeze

  def held_api(detail = HELD, **options)
    NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE, task_detail: detail, **options)
  end

  def approve(daemon, body)
    response = request(daemon, :post, "/runs/approve", token: bearer(daemon),
      body: { public_id: "al-9", task_key: "r1t0" }.merge(body))
    [response.code, JSON.parse(response.body)]
  end

  def rules(daemon) = JSON.parse(request(daemon, :get, "/rules", token: bearer(daemon)).body)

  def declared_rules(api, index) = api.configuration_declarations.fetch(index).dig("configuration", "approval_rules")

  def store = host_store

  def log(daemon) = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)

  # ---- the route: derive, approve, declare ----

  # ONE DECLARATION per grant, the rule LAST and the tool bytes unmoved;
  # the same shape again is `already` (approved, not re-declared); an edge
  # that explicitly refreshes writes the same rule set again.
  def assert_catalog_grant(before, after, rule)
    assert_equal before.except("approval_rules", "delegation_catalog"), after.except("approval_rules", "delegation_catalog")
    before.fetch("delegation_catalog").zip(after.fetch("delegation_catalog")).each do |prior, current|
      assert_equal prior.except("declaration"), current.except("declaration")
      assert_equal prior.fetch("declaration").except("approval_rules"), current.fetch("declaration").except("approval_rules")
      assert_equal prior.dig("declaration", "approval_rules") + [rule], current.dig("declaration", "approval_rules")
    end
  end

  def test_a_grant_approves_then_declares_once_with_the_rule_last_and_the_tool_bytes_unmoved
    api = held_api
    daemon = member_ready(boot, api)
    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1", run_public_id: "al-9")
    assert_equal :declared, daemon.context.declare_profile, "the boot's own declaration, before any grant"
    before = api.configuration_declarations.fetch(0).fetch("configuration")

    code, answer = approve(daemon, always: true)

    assert_equal "200", code, answer.inspect
    assert_equal "dispatched", answer.dig("task", "status"), "approved through the kernel's door first"
    assert_equal [["approve", "r1t0", nil]], api.adjudications
    granted_at = answer.dig("grant", "granted_at")
    assert_equal({ "rule" => EXACT, "granted_at" => granted_at }, answer.fetch("grant"))
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, granted_at)
    assert_equal 2, api.configuration_declarations.length, "the grant re-declared the profile once"
    after = api.configuration_declarations.fetch(1).fetch("configuration")
    assert_equal before.fetch("approval_rules") + [EXACT], after.fetch("approval_rules"), "the rule rides last"
    assert_equal before.fetch("tool_definitions"), after.fetch("tool_definitions"), "identical tool bytes"
    assert_catalog_grant(before, after, EXACT)
    assert_match(/event=grant\.added tool=bash path=command bytes=8\b/, log(daemon))
    refute_match(/npm test/, log(daemon), "the log carries the matcher's size, never its text")

    assert_equal :declared, daemon.context.declare_profile, "an explicit refresh keeps the same bytes"
    assert_equal 3, api.configuration_declarations.length

    code, answer = approve(daemon, always: true)
    assert_equal "200", code
    assert_equal({ "already" => true }, answer.fetch("grant"), "a shape already held: approved, not re-declared")
    assert_equal 2, api.adjudications.length
    assert_equal 3, api.configuration_declarations.length

    listed = rules(daemon)
    assert_equal [{ "rule" => EXACT, "run_public_id" => "al-9", "task_key" => "r1t0", "conversation" => "c-1",
                    "granted_at" => granted_at }], listed.fetch("grants")
    declared = after.fetch("approval_rules")
    assert_equal({ "rules" => declared.length, "bytes" => CybrosAgent::SizeBounds.canonical_bytesize(declared),
                   "bound" => 65_536 }, listed.fetch("declared"))
  end

  def test_an_original_hosts_grant_remains_available_when_the_default_is_unavailable
    api = held_api
    daemon = member_ready(boot, api)
    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1", run_public_id: "al-9")
    daemon.home.write_setting("workspace", "missing")

    code, answer = approve(daemon, always: true)

    assert_equal "200", code, answer.inspect
    assert_equal EXACT, answer.dig("grant", "rule")
    assert_equal EXACT, declared_rules(api, 0).last
    assert_equal [["approve", "r1t0", nil]], api.adjudications
    assert_empty api.workspace_fetches, "the original host and its profile grant need no new default"
  end

  # `--match` implies the grant; the prefix rule; a standalone run names
  # no conversation.
  def test_a_prefix_grant_rides_match_alone_and_a_standalone_run_names_no_conversation
    api = held_api
    daemon = member_ready(boot, api)

    code, answer = approve(daemon, match: "npm")

    assert_equal "200", code, answer.inspect
    assert_equal PREFIX, answer.dig("grant", "rule")
    assert_equal PREFIX, declared_rules(api, 0).last
    assert_equal [["approve", "r1t0", nil]], api.adjudications
    grant = rules(daemon).fetch("grants").fetch(0)
    assert_equal %w[rule run_public_id task_key granted_at], grant.keys, "no conversation on a standalone run"
    assert_match(/event=grant\.added tool=bash path=command bytes=5\b/, log(daemon))
  end

  def test_a_web_fetch_site_grant_approves_the_held_url_and_declares_one_rule_without_query_material
    detail = HELD.merge("tool_name" => "web_fetch", "tool_input" => { "url" => "https://docs.example.test?token=secret-value" })
    api = held_api(detail)
    daemon = member_ready(boot, api)
    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1", run_public_id: "al-9")
    assert_equal :declared, daemon.context.declare_profile
    before = api.configuration_declarations.fetch(0).fetch("configuration")
    expected = { "tool" => "web_fetch", "path" => "url", "match" => "https://docs.example.test/*", "verdict" => "allow" }

    code, answer = approve(daemon, always: true)

    assert_equal "200", code, answer.inspect
    assert_equal "dispatched", answer.dig("task", "status"), "the held slash-less URL is approved once"
    assert_equal [["approve", "r1t0", nil]], api.adjudications
    assert_equal expected, answer.dig("grant", "rule")
    after = api.configuration_declarations.fetch(1).fetch("configuration")
    assert_equal before.fetch("approval_rules") + [expected], after.fetch("approval_rules")
    assert_catalog_grant(before, after, expected)
    assert_equal [expected], rules(daemon).fetch("grants").map { |grant| grant.fetch("rule") }
    refute_includes log(daemon), "secret-value"

    detail.fetch("tool_input")["url"] = "https://docs.example.test/another?query=1"
    code, answer = approve(daemon, match: "https://docs.example.test/")
    assert_equal "200", code
    assert_equal({ "already" => true }, answer.fetch("grant"))
    assert_equal 2, api.configuration_declarations.length, "another path at the same literal site adds no new rule"
    assert_equal 2, api.adjudications.length
  end

  def test_an_invalid_web_fetch_site_grant_refuses_before_approval_or_declaration
    daemon = member_ready(boot, held_api)
    [
      ["https://docs.example.test/guide", { match: "https://other.example.test" }],
      ["https://docs.example.test/guide", { match: "https://docs.example.test/guide" }],
      ["https://docs.example.test/guide", { match: "https://docs.example.test?query=1" }],
      ["https://docs*.example.test/guide", { always: true }],
      ["https://secret-user:secret-password@docs.example.test/guide", { always: true }],
    ].each do |url, body|
      api = held_api(HELD.merge("tool_name" => "web_fetch", "tool_input" => { "url" => url }))
      daemon.wire.api_transport = api

      code, answer = approve(daemon, body)

      assert_equal "400", code, answer.inspect
      assert_equal "malformed_body", answer.dig("error", "code")
      refute_includes answer.dig("error", "message"), "secret-password"
      assert_empty api.adjudications
      assert_empty api.configuration_declarations
    end
    assert_empty rules(daemon).fetch("grants")
  end

  def test_a_nexus_mcp_grant_names_the_callable_without_local_command_semantics
    detail = HELD.merge("tool_name" => "web_fetch", "tool_alias" => "company_lookup",
      "tool_input" => { "query" => "invoices" },
      "target" => { "kind" => "mcp", "connection_public_id" => SecureRandom.uuid_v7, "tool_name" => "web_fetch" })
    api = held_api(detail)
    daemon = member_ready(boot, api)

    code, answer = approve(daemon, always: true)

    assert_equal "200", code, answer.inspect
    expected = { "tool" => "company_lookup", "verdict" => "allow" }
    assert_equal expected, answer.dig("grant", "rule")
    assert_equal expected, declared_rules(api, 0).last
    assert_equal [["approve", "r1t0", nil]], api.adjudications

    code, answer = approve(daemon, match: "https://example.test")
    assert_equal "400", code
    assert_includes answer.dig("error", "message"), "company_lookup is granted whole"
    assert_equal 1, api.adjudications.length
  end

  # THE FIVE REFUSALS, before anything moves: no approve reaches the kernel,
  # nothing is declared, and each sentence is the derivation's own.
  def test_a_derivation_refusal_is_400_before_the_kernel_sees_anything
    api = held_api
    daemon = member_ready(boot, api)

    cases = {
      { always: true, match: "echo" } =>
        "--match must be a whole-token prefix of the held command, followed by \" \": \"npm test\"",
      { match: "p" } => "--match must be a whole-token prefix of the held command, followed by \" \": \"npm test\"",
      { match: "" } => "--match is literal text and cannot be blank; the kernel reads * and ? as wildcards",
      { match: "np*" } => "--match is literal text and cannot be blank; the kernel reads * and ? as wildcards",
    }
    cases.each do |body, sentence|
      code, answer = approve(daemon, body)
      assert_equal "400", code, body.inspect
      assert_equal({ "code" => "malformed_body", "message" => sentence }, answer.fetch("error"), body.inspect)
    end

    daemon.wire.api_transport = held_api(HELD.merge("tool_input" => { "command" => "ls *.rb" }))
    code, answer = approve(daemon, always: true)
    assert_equal "400", code
    assert_equal "the held command contains * or ?, which the kernel reads as wildcards; grant a prefix with --match instead",
      answer.dig("error", "message")

    daemon.wire.api_transport = held_api(HELD.merge("tool_input" => { "workdir" => "/tmp" }))
    code, answer = approve(daemon, always: true)
    assert_equal "400", code
    assert_equal "the held call carries no command text to key a grant on", answer.dig("error", "message")

    daemon.wire.api_transport = held_api(HELD.merge("tool_name" => "stop_process", "tool_input" => { "id" => "p3" }))
    code, answer = approve(daemon, match: "p")
    assert_equal "400", code
    assert_equal "--match narrows a text-keyed tool (bash, start_process, write, edit); stop_process is granted whole",
      answer.dig("error", "message")

    daemon.wire.api_transport = held_api(HELD.merge("status" => "dispatched"))
    code, answer = approve(daemon, always: true)
    assert_equal "400", code
    assert_equal "r1t0 is not held for approval (dispatched); a grant keys on a held call", answer.dig("error", "message")

    code, answer = approve(daemon, match: 3)
    assert_equal "400", code
    assert_equal "match must be a string", answer.dig("error", "message")

    assert_empty api.adjudications, "no refused derivation reached the kernel"
    assert_empty api.configuration_declarations
    assert_empty rules(daemon).fetch("grants")
    refute_match(/event=grant\./, log(daemon))
  end

  # A WHOLE-TOOL GRANT on a row that is not text-keyed; a plain approve
  # (no flag) grants nothing.
  def test_a_whole_tool_grant_and_a_plain_approve
    api = held_api(HELD.merge("tool_name" => "stop_process", "tool_input" => { "id" => "p3" }))
    daemon = member_ready(boot, api)

    code, answer = approve(daemon, {})
    assert_equal "200", code
    refute answer.key?("grant"), "no flag: the decision alone"
    assert_empty api.configuration_declarations

    code, answer = approve(daemon, always: true)
    assert_equal "200", code
    assert_equal({ "tool" => "stop_process", "verdict" => "allow" }, answer.dig("grant", "rule"))
    assert_equal({ "tool" => "stop_process", "verdict" => "allow" }, declared_rules(api, 0).last)
    assert_match(/event=grant\.added tool=stop_process path=- bytes=0\b/, log(daemon))
  end

  # THE REFUSED DECLARATION: the kernel refuses the list, `declare`
  # answers `Refused`, the grant it just added is REVOKED before any later
  # edge could re-send it, the log says so by code, the call still ran.
  def test_a_kernel_refusal_revokes_the_grant_and_answers_refused
    refusal = CybrosAgent::Response.new(status: 413, headers: {},
      body: { "error" => { "code" => "envelope_bound", "message" => "approval_rules exceeds 65536 bytes" } })
    api = held_api(configuration: refusal)
    daemon = member_ready(boot, api)

    code, answer = approve(daemon, always: true)

    assert_equal "200", code, answer.inspect
    assert_equal "dispatched", answer.dig("task", "status"), "the call ran"
    assert_equal({ "refused" => "envelope_bound" }, answer.fetch("grant"))
    assert_equal 1, api.configuration_declarations.length, "one attempt, refused"
    assert_empty rules(daemon).fetch("grants"), "revoked"
    assert_match(/event=grant\.refused tool=bash path=command bytes=8 code=envelope_bound\b/, log(daemon))
    refute_match(/event=grant\.added/, log(daemon))
    outcome = daemon.context.declare_profile
    assert_kind_of Rho::Daemon::HostFollowers::Refused, outcome, "the outcome relays"
    assert_equal "envelope_bound", outcome.code
    assert_equal 2, api.configuration_declarations.length
    assert_empty declared_rules(api, 1) & [EXACT], "a later edge never re-sends the refused rule"
  end

  def test_a_refused_main_declaration_stops_a_grant_before_any_named_agent_receives_it
    api = held_api(user_public_id: IDENTITY.user_public_id, configuration: declaration_refusal,
      named_agents: [grant_agent("reviewer"), grant_agent("writer")])
    daemon = member_ready(boot, api)

    code, answer = approve(daemon, always: true)

    assert_equal "200", code, answer.inspect
    assert_equal "dispatched", answer.dig("task", "status"), "the one-time approval remains successful"
    assert_equal({ "refused" => "envelope_bound" }, answer.fetch("grant"))
    assert_empty rules(daemon).fetch("grants")
    assert_empty api.named_agent_declarations, "no private named row can persist the rejected grant"
    assert_equal 1, api.configuration_declarations.length
  end

  def test_a_grant_already_in_every_preset_still_requires_a_current_main_write
    declaration_answer = :accept
    api = held_api(configuration: ->(_body) { declaration_answer })
    daemon = member_ready(boot, api)
    daemon.context.agent_presets do |catalog|
      catalog.list.each do |preset|
        catalog.replace(preset.public_id, name: preset.name, description: preset.description,
          configuration: preset.configuration.merge("approval_rules" => [EXACT]))
      end
    end
    assert_equal :declared, daemon.context.declare_profile
    before = api.configuration_declarations.last
    declaration_answer = declaration_refusal

    code, answer = approve(daemon, always: true)

    assert_equal "200", code, answer.inspect
    assert_equal "dispatched", answer.dig("task", "status")
    assert_equal({ "refused" => "envelope_bound" }, answer.fetch("grant"))
    assert_empty daemon.host_followers.grants
    assert_equal 2, api.configuration_declarations.length, "identical candidate bytes still need an actual main write"
    assert_equal before, api.configuration_declarations.last
  end

  def test_a_named_server_failure_does_not_revoke_a_grant_already_written_to_the_main_profile
    unavailable = CybrosAgent::Response.new(status: 503, headers: {},
      body: { "error" => { "code" => "unavailable", "message" => "later" } })
    api = held_api(user_public_id: IDENTITY.user_public_id,
      named_agents: [grant_agent("reviewer"), grant_agent("writer")],
      named_agent: ->(name, _body) { name == "reviewer" ? unavailable : :accept })
    daemon = member_ready(boot, api)

    code, answer = approve(daemon, always: true)

    assert_equal "200", code, answer.inspect
    assert_equal EXACT, answer.dig("grant", "rule")
    assert_equal [EXACT], rules(daemon).fetch("grants").map { |grant| grant.fetch("rule") }
    assert_equal EXACT, declared_rules(api, 0).last
    assert_equal ["reviewer"], daemon.host_followers.named_edge.failed
    assert_equal ["writer"], daemon.host_followers.named_edge.declared
    assert_equal EXACT, api.own_named_agent("writer").dig("configuration", "approval_rules").last
    paths = api.requests.map(&:first)
    assert_operator paths.index("/agent_api/v1/profile/configuration"), :<, paths.index("/agent_api/v1/profile/agents/reviewer")
    assert_match(/event=agents\.declaration_failed name=reviewer code=unavailable/, log(daemon))
    assert_match(/event=grant\.added/, log(daemon))
  end

  def test_a_declaration_refusal_prevents_stop_from_claiming_remote_grants_were_revoked
    declaration_answer = :accept
    api = held_api(configuration: ->(_body) { declaration_answer })
    daemon = member_ready(boot, api)
    approve(daemon, always: true)
    declaration_answer = declaration_refusal

    daemon.stop

    assert_empty daemon.host_followers.grants
    assert_match(/event=grants\.revoke_failed count=1 code=envelope_bound/, log(daemon))
    refute_match(/event=grants\.revoked_at_stop/, log(daemon))
  end

  # THE FOURTH MEMBER (S20): the policy half of the declaration is in the
  # tuple, so a compaction-policy change alone re-declares while the tool
  # bytes stay byte-identical.
  def test_a_policy_change_alone_re_declares_under_the_fourth_member
    api = held_api
    daemon = member_ready(boot, api)
    assert_equal :declared, daemon.context.declare_profile
    assert_equal :declared, daemon.context.declare_profile

    daemon.host_followers.define_singleton_method(:compaction_policy) { { "mode" => "kernel", "budget_tokens" => 4096 } }
    assert_equal :declared, daemon.context.declare_profile

    assert_equal 3, api.configuration_declarations.length
    first, second = api.configuration_declarations.values_at(0, 2).map { |body| body.fetch("configuration") }
    assert_equal first.fetch("tool_definitions"), second.fetch("tool_definitions")
    assert_equal({ "mode" => "kernel", "budget_tokens" => 4096 }, second.fetch("compaction_policy"))
    refute_equal first.fetch("compaction_policy"), second.fetch("compaction_policy")
  end

  # TWO CONCURRENT GRANTS (S24) serialize under the one mutex: two writes
  # in order, the first carrying one rule, the second both, and the
  # daemon's list equal to the last-written list's tail.
  # THE STATED PROPERTY, not a correlate: the fake records a declaration
  # when its bytes ARRIVE (as the kernel applies a PUT) and parks the first
  # write on the reactor longer than the second — so without the gate the
  # second grant's two-rule list would land FIRST and the first grant's
  # one-rule list last, the kernel's row ending one grant short while the
  # daemon holds both. Under the gate the second waits for the first.
  def test_two_concurrent_grants_serialize_into_two_writes_in_order
    delays = [0.3, 0.0]
    api = held_api(configuration: lambda { |_body|
      sleep(delays.shift || 0)
      :accept
    })
    daemon = member_ready(boot, api)

    answers = [{ always: true }, { match: "npm" }].map do |body|
      Thread.new { approve(daemon, body) }
    end.map(&:value)

    assert_equal %w[200 200], answers.map(&:first), answers.inspect
    assert_equal 2, api.configuration_declarations.length, "two writes, one per grant"
    first, second = [0, 1].map { |index| declared_rules(api, index) }
    assert_equal 1, (first & [EXACT, PREFIX]).length, "the first write carries one grant"
    assert_equal [EXACT, PREFIX].sort_by(&:to_a), second.last(2).sort_by(&:to_a), "the second carries both"
    assert_equal second.last(2), rules(daemon).fetch("grants").map { |grant| grant.fetch("rule") },
      "the daemon's list is the last-written list's tail, in order"
  end

  # THE ONE LIST reaches the standalone shell (S21): `POST /runs` authors
  # the daemon's list — the constant, the roots' denies and the grants —
  # where it named the bare constant.
  def test_the_standalone_shell_authors_the_one_list_with_the_grants
    api = held_api
    daemon = member_ready(boot, api)
    approve(daemon, always: true)

    response = request(daemon, :post, "/runs", token: bearer(daemon),
      body: { "prompt" => "fix it", "model" => "dev/mock-text", "idempotency_key" => "k-a" })

    assert_equal "201", response.code, response.body
    authored = api.run_creates.fetch(0).dig("run", "approval_rules")
    assert_equal Rho::RunDeclaration.approval_rules(roots: Rho.protected_roots(daemon.home), grants: [EXACT]), authored
    assert_equal EXACT, authored.last
    assert_equal daemon.context.approval_rules, authored
  end

  # THE CLEAN STOP (S23): the grants are re-declared away on the shutdown
  # edge — the constant list written, `grants.revoked_at_stop` logged — so
  # only a daemon that DIES leaves a grant standing until its next boot.
  def test_a_clean_stop_re_declares_the_constant_list_and_logs_the_count
    api = held_api
    daemon = member_ready(boot, api)
    assert_equal :declared, daemon.context.declare_profile
    approve(daemon, always: true)
    approve(daemon, match: "npm")
    assert_equal 3, api.configuration_declarations.length

    daemon.stop

    assert_equal 4, api.configuration_declarations.length, "one more write on the stop edge"
    assert_equal declared_rules(api, 0), declared_rules(api, 3), "the list as before any grant"
    assert_match(/event=grants\.revoked_at_stop count=2\b/, log(daemon))
  end

  # A stop with nothing granted writes nothing.
  def test_a_stop_with_no_grant_writes_nothing
    api = held_api
    daemon = member_ready(boot, api)

    daemon.stop

    assert_empty api.configuration_declarations
    refute_match(/event=grants\./, log(daemon))
  end

  # A stop whose re-declaration the kernel refuses logs the code and stops
  # all the same: best effort, never a hang, never a raise.
  def test_a_refused_revoke_at_stop_is_logged_and_the_daemon_still_stops
    refusal = CybrosAgent::Response.new(status: 422, headers: {},
      body: { "error" => { "code" => "validation_failed", "message" => "approval_rules is invalid" } })
    api = held_api
    daemon = member_ready(boot, api)
    approve(daemon, always: true)
    api.instance_variable_set(:@configuration, refusal)

    daemon.stop

    refute_predicate daemon, :running?
    assert_match(/event=grants\.revoke_failed count=1 code=validation_failed\b/, log(daemon))
    refute_match(/event=grants\.revoked_at_stop/, log(daemon))
  end

  def declaration_refusal
    CybrosAgent::Response.new(status: 413, headers: {},
      body: { "error" => { "code" => "envelope_bound", "message" => "Declaration too large" } })
  end

  def grant_agent(name)
    {
      "public_id" => "na-#{name}", "handle" => name, "name" => name, "kind" => "agent", "display_name" => name,
      "agent_identifier" => "rho.fake/#{name}", "steward_public_id" => "0199-steward", "scope" => "steward",
      "description" => "Private helper", "derived_from_public_id" => IDENTITY.user_public_id,
      "system_prompt" => nil, "summarizer" => nil,
      "configuration" => { "tool_definitions" => [], "kernel_tools" => [], "runner_executor_public_ids" => [],
        "runner_tool_names" => nil, "mcp_tools" => [], "approval_mode" => "bypass", "approval_rules" => nil,
        "prompt_mechanism" => "default", "prompt_template" => nil, "compaction_policy" => nil,
        "default_model" => nil, "fallback_models" => [] },
    }
  end
end
