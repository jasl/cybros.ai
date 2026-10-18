require "test_helper"

# THE ROW GRAMMAR: faults are per server, the table's
# shape alone refuses the extension, `${NAME}` expands from the daemon's
# environment naming keys never values, the vocabulary is the runner's.
class SettingsTest < Minitest::Test
  STDIO = { "transport" => "stdio", "command" => "ruby", "args" => ["server.rb"], "tools" => ["echo"] }.freeze
  HTTP = { "transport" => "http", "url" => "https://mcp.example.com/mcp", "tools" => ["*"] }.freeze

  def parse(table, env: {})
    Rho::Mcp::Settings.parse(table, env: env, home: "/home/x")
  end

  def test_a_stdio_row_parses_with_its_defaults
    row = parse({ "fx" => STDIO }).fetch(0)
    assert_kind_of Rho::Mcp::Settings::Row, row
    assert_equal ["fx", "stdio", "ruby", ["server.rb"], "/home/x", :runner], row.to_h.values_at(:key, :transport, :command, :args, :cwd, :serves)
    assert_nil row.timeout_ms, "a stdio server's park is the kernel's default"
    assert_equal 30_000, row.startup_timeout_ms
    assert_equal({}, row.env)
    assert_equal ["echo"], row.tools
    assert row.allows?("echo")
    refute row.allows?("write")
    assert_equal "ruby server.rb", row.launch
    assert_empty row.secrets
  end

  def test_an_http_row_defaults_to_the_agent_with_a_sixty_second_park
    row = parse({ "remote" => HTTP }).fetch(0)
    assert_equal [:agent, 60_000, "https://mcp.example.com/mcp"], row.to_h.values_at(:serves, :timeout_ms, :url)
    assert row.all_tools?
    assert row.allows?("anything")
    assert_equal :runner, parse({ "remote" => HTTP.merge("serves" => "runner") }).fetch(0).serves
  end

  def test_secrets_expand_from_the_environment_and_every_header_value_is_a_secret
    table = { "fx" => STDIO.merge("env" => { "FX_TOKEN" => "${FX_TOKEN}", "PLAIN" => "x" }),
              "remote" => HTTP.merge("headers" => { "Authorization" => "Bearer ${REMOTE_TOKEN}", "X-Api-Key" => "literal-key-123" }) }
    fx, remote = parse(table, env: { "FX_TOKEN" => "fxsecret-9876543210", "REMOTE_TOKEN" => "rtsecret-0123456789" })
    assert_equal({ "FX_TOKEN" => "fxsecret-9876543210", "PLAIN" => "x" }, fx.env)
    assert_equal ["fxsecret-9876543210"], fx.secrets
    assert_equal({ "Authorization" => "Bearer rtsecret-0123456789", "X-Api-Key" => "literal-key-123" }, remote.headers)
    assert_equal ["rtsecret-0123456789", "Bearer rtsecret-0123456789", "literal-key-123"], remote.secrets
  end

  # sec-4: a credential TYPED into the file under a credential-shaped env
  # key is a secret like an expansion is; a short literal (a flag, a port)
  # and a literal under a plain key are not.
  def test_a_literal_under_a_credential_shaped_env_key_is_a_secret
    table = { "fx" => STDIO.merge("env" => { "OPENAI_API_KEY" => "sk-literal-1234567890", "DEBUG_KEY" => "1",
                                            "PORT" => "80808080", "FX_TOKEN" => "${FX_TOKEN}" }) }
    row = parse(table, env: { "FX_TOKEN" => "fxsecret-9876543210" }).fetch(0)
    assert_equal ["sk-literal-1234567890", "fxsecret-9876543210"], row.secrets
  end

  def test_an_unset_variable_is_that_rows_fault_naming_the_key_never_a_value
    fx, other = parse({ "fx" => STDIO.merge("env" => { "FX_TOKEN" => "${FX_TOKEN}" }), "other" => STDIO }, env: {})
    assert_kind_of Rho::Mcp::Settings::Fault, fx
    assert_equal 'mcp server "fx": env.FX_TOKEN names ${FX_TOKEN}, which is not set in the daemon\'s environment', fx.sentence
    assert_equal ["stdio", "runner"], [fx.transport, fx.serves]
    assert_equal [true, nil, {}, {}, false, false, false], [fx.fault?, fx.launch, fx.env, fx.headers, fx.stdio?, fx.http?, fx.oauth?],
      "a fault answers every member a row does — it launches nothing, carries nothing, is no door"
    assert_kind_of Rho::Mcp::Settings::Row, other, "the other server keeps its row"
  end

  def test_the_refusal_without_an_allowlist_is_a_sentence_naming_the_probe
    fault = parse({ "fx" => STDIO.except("tools") }).fetch(0)
    assert_kind_of Rho::Mcp::Settings::Fault, fault
    assert_equal 'mcp server "fx" names no tools — name the ones you want under "tools", or ["*"] to take every one; ' \
                 "`rho mcp probe fx` prints what it would declare and the bytes", fault.sentence
    assert_equal 'mcp server "fx": tools must be a non-empty list of the server\'s tool names, or ["*"]',
      parse({ "fx" => STDIO.merge("tools" => []) }).fetch(0).sentence
  end

  def test_every_row_level_fault_has_its_sentence
    cases = {
      STDIO.merge("transport" => "grpc") => 'mcp server "fx": transport must be one of stdio, http, got "grpc"',
      STDIO.except("command") => 'mcp server "fx": a stdio server needs a "command" (a string)',
      HTTP.except("url") => 'mcp server "fx": an http server needs a "url" (a string)',
      HTTP.merge("url" => "ftp://x") => 'mcp server "fx": url must be http:// or https://',
      STDIO.merge("serves" => "provider") => 'mcp server "fx": serves must be one of runner, agent, got "provider"',
      STDIO.merge("timeout_ms" => 0) => 'mcp server "fx": timeout_ms must be a positive integer of milliseconds no greater than 604800000, got 0',
      STDIO.merge("startup_timeout_ms" => "soon") => 'mcp server "fx": startup_timeout_ms must be a positive integer of milliseconds no greater than 604800000, got "soon"',
      STDIO.merge("args" => "server.rb") => 'mcp server "fx": args must be an array of strings',
      STDIO.merge("bogus" => 1) => 'mcp server "fx": "bogus" is not a key of a server row (the keys: transport, command, args, env, cwd, url, headers, tools, timeout_ms, startup_timeout_ms, serves, effect_profiles, oauth, enabled)',
      STDIO.merge("env" => { "A" => 1 }) => 'mcp server "fx": env.A must be a string',
      HTTP.merge("url" => "http://mcp.example.com/mcp", "headers" => { "Authorization" => "Bearer x" }) =>
        'mcp server "fx": header Authorization carries a credential over plain http:// to mcp.example.com; use https://, or a loopback host',
      HTTP.merge("url" => "http://mcp.example.com/mcp", "headers" => { "X-Api-Key" => "k" }) =>
        'mcp server "fx": header X-Api-Key carries a credential over plain http:// to mcp.example.com; use https://, or a loopback host',
      # sec-5: every header value is a secret, so the refusal is by presence, not by the header's name.
      HTTP.merge("url" => "http://mcp.example.com/mcp", "headers" => { "Cookie" => "session=abc" }) =>
        'mcp server "fx": header Cookie carries a credential over plain http:// to mcp.example.com; use https://, or a loopback host',
      HTTP.merge("url" => "http://mcp.example.com/mcp", "headers" => { "X-Auth" => "x", "Authorization" => "Bearer x" }) =>
        'mcp server "fx": header X-Auth carries a credential over plain http:// to mcp.example.com; use https://, or a loopback host',
    }
    cases.each do |raw, sentence|
      fault = parse({ "fx" => raw }).fetch(0)
      assert_kind_of Rho::Mcp::Settings::Fault, fault, raw.inspect
      assert_equal sentence, fault.sentence
    end
    assert_kind_of Rho::Mcp::Settings::Row,
      parse({ "fx" => HTTP.merge("url" => "http://localhost:8080/mcp", "headers" => { "Authorization" => "Bearer x" }) }).fetch(0),
      "a bearer over loopback http is this machine's own"
    assert_kind_of Rho::Mcp::Settings::Row, parse({ "fx" => HTTP.merge("url" => "http://mcp.example.com/mcp") }).fetch(0),
      "plain http with no header carries no secret"
  end

  # THE SWITCH (`enabled`; `rho mcp enable NAME` writes it): absent is on —
  # a row a person wrote is wanted; `false` parks the row (listed, never
  # connected, never announced); anything else is the row's fault, and a
  # parked row that is broken still carries its sentence.
  def test_enabled_defaults_to_true_parses_false_and_refuses_anything_else
    assert_predicate parse({ "fx" => STDIO }).fetch(0), :enabled?
    assert_predicate parse({ "fx" => STDIO.merge("enabled" => true) }).fetch(0), :enabled?
    refute_predicate parse({ "fx" => STDIO.merge("enabled" => false) }).fetch(0), :enabled?
    fault = parse({ "fx" => STDIO.merge("enabled" => "yes") }).fetch(0)
    assert_kind_of Rho::Mcp::Settings::Fault, fault
    assert_equal 'mcp server "fx": enabled must be true or false, got "yes"', fault.sentence
    assert_predicate fault, :enabled?, "a fault is listed by its sentence whatever `enabled` says"
    fault = parse({ "fx" => STDIO.merge("enabled" => false, "transport" => "grpc") }).fetch(0)
    assert_kind_of Rho::Mcp::Settings::Fault, fault
    assert_equal 'mcp server "fx": transport must be one of stdio, http, got "grpc"', fault.sentence
  end

  # THE OAUTH SUB-OBJECT: two optional tunings;
  # the four faults; `oauth?` by the gem's own secure-URL predicate and the
  # header's name in any case.
  def test_oauth_parses_its_two_members_and_defaults_them
    row = parse({ "fx" => HTTP.merge("oauth" => { "client_id" => "rho-at-acme", "callback_port" => 3118 }) }).fetch(0)
    assert_equal Rho::Mcp::Settings::Oauth.new(client_id: "rho-at-acme", callback_port: 3118), row.oauth
    assert_equal Rho::Mcp::Settings::Oauth.new(client_id: nil, callback_port: nil), parse({ "fx" => HTTP.merge("oauth" => {}) }).fetch(0).oauth
    assert_nil parse({ "fx" => HTTP }).fetch(0).oauth, "absent is the defaults; the row is OAuth-capable regardless"
  end

  def test_oauth_capable_is_a_secure_url_with_no_authorization_header_of_any_spelling
    assert_predicate parse({ "fx" => HTTP }).fetch(0), :oauth?
    assert_predicate parse({ "fx" => HTTP.merge("url" => "http://localhost:8080/mcp") }).fetch(0), :oauth?
    assert_predicate parse({ "fx" => HTTP.merge("url" => "http://127.0.0.1:8080/mcp", "headers" => { "X-Api-Key" => "k" }) }).fetch(0), :oauth?,
      "a header beside OAuth is fine; only a bearer is the other door"
    refute_predicate parse({ "fx" => HTTP.merge("url" => "http://mcp.example.com/mcp") }).fetch(0), :oauth?, "plain http off loopback"
    refute_predicate parse({ "fx" => HTTP.merge("headers" => { "Authorization" => "Bearer x" }) }).fetch(0), :oauth?
    refute_predicate parse({ "fx" => HTTP.merge("headers" => { "authorization" => "Bearer x" }) }).fetch(0), :oauth?
    refute_predicate parse({ "fx" => STDIO }).fetch(0), :oauth?
    refute_predicate parse({ "fx" => STDIO }).fetch(0), :secure_url?
    assert_predicate parse({ "fx" => HTTP.merge("headers" => { "AUTHORIZATION" => "x" }) }).fetch(0), :authorization_header?
  end

  def test_the_four_oauth_faults_have_their_sentences
    cases = {
      STDIO.merge("oauth" => {}) => 'mcp server "fx": oauth is an http server\'s; a stdio server reads its credentials from `env`',
      HTTP.merge("oauth" => {}, "headers" => { "Authorization" => "Bearer x" }) => 'mcp server "fx": either a bearer header or oauth, not both',
      HTTP.merge("oauth" => {}, "headers" => { "authorization" => "Bearer x" }) => 'mcp server "fx": either a bearer header or oauth, not both',
      HTTP.merge("oauth" => {}, "url" => "http://mcp.example.com/mcp") => 'mcp server "fx": oauth needs https://, or a loopback host',
      HTTP.merge("oauth" => { "callback_port" => 0 }) => 'mcp server "fx": oauth.callback_port must be an integer from 1 to 65535, got 0',
      HTTP.merge("oauth" => { "callback_port" => "3118" }) => 'mcp server "fx": oauth.callback_port must be an integer from 1 to 65535, got "3118"',
      HTTP.merge("oauth" => { "client_id" => 7 }) => 'mcp server "fx": oauth.client_id must be a string',
      HTTP.merge("oauth" => { "scope" => "read" }) => 'mcp server "fx": "scope" is not a key of oauth (the keys: client_id, callback_port)',
      HTTP.merge("oauth" => "rho-at-acme") => 'mcp server "fx": oauth must be an object',
    }
    cases.each do |raw, sentence|
      fault = parse({ "fx" => raw }).fetch(0)
      assert_kind_of Rho::Mcp::Settings::Fault, fault, raw.inspect
      assert_equal sentence, fault.sentence
    end
    assert_kind_of Rho::Mcp::Settings::Row, parse({ "fx" => HTTP.merge("oauth" => {}, "url" => "http://[::1]:8080/mcp") }).fetch(0),
      "the gem's loopback: IPv6 too"
  end

  def test_effect_profile_overrides_are_judged_by_the_runners_vocabulary_at_parse
    good = { "kind" => "read_only", "destructive" => false, "effect_scope" => "closed", "idempotency" => "intrinsic",
             "reconciliation" => "none" }
    row = parse({ "fx" => STDIO.merge("effect_profiles" => { "echo" => good }) }).fetch(0)
    assert_equal({ "echo" => good }, row.effect_profiles)
    assert_predicate row.effect_profiles.fetch("echo"), :frozen?

    fault = parse({ "fx" => STDIO.merge("effect_profiles" => { "lookup" => good.merge("kind" => "readonly") }) }).fetch(0)
    assert_equal 'mcp server "fx": effect_profiles.lookup must be a full effect profile with kind one of "pure", "read_only", "write", not "readonly"',
      fault.sentence
    fault = parse({ "fx" => STDIO.merge("effect_profiles" => { "lookup" => { "kind" => "read_only" } }) }).fetch(0)
    assert_equal 'mcp server "fx": effect_profiles.lookup must be a full effect profile with exactly kind, destructive, effect_scope, idempotency, reconciliation',
      fault.sentence
  end

  def test_only_a_malformed_table_refuses_the_extension
    error = assert_raises(Rho::Mcp::Settings::Malformed) { parse(["fx"]) }
    assert_equal "MCP servers must be an object of objects", error.message
    error = assert_raises(Rho::Mcp::Settings::Malformed) { parse({ "fx" => "ruby" }) }
    assert_equal "MCP servers[fx] must be an object", error.message
    ["Fx", "my_server", "-fx", "fx-", "a--b", "x" * 33].each do |key|
      error = assert_raises(Rho::Mcp::Settings::Malformed, key) { parse({ key => STDIO }) }
      assert_includes error.message, "MCP servers names #{key.inspect}"
    end
    assert_kind_of Rho::Runner::Extensions::RegistrationError, Rho::Mcp::Settings::Malformed.new("x")
  end

  # THE EDITOR'S ROWS: the ACP
  # `mcpServers` shape translated into the boot grammar — `serves: agent`,
  # `tools: ["*"]`, the defaults, the secrets built as the boot table's are
  # (every header value; a literal under a credential-shaped env key),
  # values LITERAL; `sse`/`acp` a fault row; a malformed entry an
  # `ArgumentError` naming it.
  def from_acp(entries) = Rho::Mcp::Settings.from_acp(entries, home: "/home/x")

  def test_from_acp_translates_stdio_and_http_entries_into_agent_rows_taking_every_tool
    stdio, http = from_acp([
      { "name" => "fx", "command" => "ruby", "args" => ["srv.rb"],
        "env" => [{ "name" => "FX_TOKEN", "value" => "fx-secret-token-0123" }, { "name" => "PLAIN", "value" => "x" }] },
      { "type" => "http", "name" => "remote", "url" => "https://mcp.example.com/mcp",
        "headers" => [{ "name" => "X-Api-Key", "value" => "literal-key-123" }, { "name" => "X-Plain", "value" => "1" }] },
    ])
    assert_kind_of Rho::Mcp::Settings::Row, stdio
    assert_equal ["fx", "stdio", "ruby", ["srv.rb"], "/home/x", :agent, ["*"]],
      stdio.to_h.values_at(:key, :transport, :command, :args, :cwd, :serves, :tools)
    assert_equal({ "FX_TOKEN" => "fx-secret-token-0123", "PLAIN" => "x" }, stdio.env)
    assert_equal ["fx-secret-token-0123"], stdio.secrets, "a literal under a credential-shaped env key is a secret"
    assert_equal [nil, 30_000, {}, nil, true], stdio.to_h.values_at(:timeout_ms, :startup_timeout_ms, :effect_profiles, :oauth, :enabled)
    assert_kind_of Rho::Mcp::Settings::Row, http
    assert_equal ["remote", "http", "https://mcp.example.com/mcp", :agent, ["*"], 60_000, nil],
      http.to_h.values_at(:key, :transport, :url, :serves, :tools, :timeout_ms, :command)
    assert_equal({ "X-Api-Key" => "literal-key-123", "X-Plain" => "1" }, http.headers)
    assert_equal ["literal-key-123", "1"], http.secrets, "every header value is a secret"
    assert_predicate http, :oauth?, "the row's own predicates stand; the report is where a conversation row has no login door"
    refute_predicate stdio, :fault?
  end

  def test_from_acp_takes_values_verbatim_with_stdio_named_or_implied_and_the_lists_optional
    bare = from_acp([{ "type" => "stdio", "name" => "fx", "command" => "ruby" }]).fetch(0)
    assert_equal [[], {}, [], "stdio"], [bare.args, bare.env, bare.secrets, bare.transport]
    literal = from_acp([{ "name" => "fx", "command" => "ruby", "env" => [{ "name" => "FX_TOKEN", "value" => "${FX_TOKEN}" }] }]).fetch(0)
    assert_kind_of Rho::Mcp::Settings::Row, literal
    assert_equal({ "FX_TOKEN" => "${FX_TOKEN}" }, literal.env, "an editor resolved its values: no ${NAME} expansion, no unset fault")
    assert_equal ["${FX_TOKEN}"], literal.secrets
    assert_equal [], from_acp([])
    free = from_acp([{ "name" => "My Server", "command" => "ruby", "extra" => "ignored" }]).fetch(0)
    assert_equal "My Server", free.key, "an editor names its servers freely; a stranger key is not the editor's fault"
    assert_match(/\Amcp__My_Server__echo_[0-9a-f]{12}\z/, Rho::Mcp::Naming.tool(free.key, "echo"))
  end

  def test_from_acp_faults_an_sse_or_acp_entry_as_a_row_and_keeps_the_boot_grammars_policy_faults
    sse, acp = from_acp([{ "type" => "sse", "name" => "events", "url" => "https://mcp.example.com/sse" }, { "type" => "acp", "name" => "peer" }])
    assert_kind_of Rho::Mcp::Settings::Fault, sse
    assert_equal ["events", "sse", "agent", "transport sse unsupported"], [sse.key, sse.transport, sse.serves, sse.sentence]
    assert_predicate sse, :fault?
    assert_equal ["peer", "acp", "transport acp unsupported"], [acp.key, acp.transport, acp.sentence]

    plain = from_acp([{ "type" => "http", "name" => "plain", "url" => "http://mcp.example.com/mcp",
                        "headers" => [{ "name" => "X-Api-Key", "value" => "k" }] }]).fetch(0)
    assert_kind_of Rho::Mcp::Settings::Fault, plain
    assert_equal 'mcp server "plain": header X-Api-Key carries a credential over plain http:// to mcp.example.com; use https://, or a loopback host',
      plain.sentence
    assert_equal ["http", "agent"], [plain.transport, plain.serves]
    assert_kind_of Rho::Mcp::Settings::Row,
      from_acp([{ "type" => "http", "name" => "local", "url" => "http://127.0.0.1:4000/mcp", "headers" => [{ "name" => "X-Api-Key", "value" => "k" }] }]).fetch(0),
      "the mock world's loopback fixture with a header"
    assert_equal 'mcp server "ftp": url must be http:// or https://', from_acp([{ "type" => "http", "name" => "ftp", "url" => "ftp://x" }]).fetch(0).sentence
  end

  def test_from_acp_refuses_a_malformed_entry_with_a_sentence_naming_it_before_anything_else
    cases = {
      "nope" => "mcpServers must be an array of server entries",
      ["nope"] => "mcpServers[0] must be an object",
      [{ "command" => "ruby" }] => 'mcpServers[0] needs a "name" (a string)',
      [{ "name" => "", "command" => "ruby" }] => 'mcpServers[0] needs a "name" (a string)',
      [{ "name" => "fx" }] => 'mcpServers[0] ("fx"): a stdio server needs a "command" (a string)',
      [{ "name" => "fx", "command" => "" }] => 'mcpServers[0] ("fx"): a stdio server needs a "command" (a string)',
      [{ "name" => "fx", "command" => "ruby", "args" => "srv.rb" }] => 'mcpServers[0] ("fx"): args must be an array of strings',
      [{ "name" => "fx", "command" => "ruby", "env" => { "A" => "b" } }] => 'mcpServers[0] ("fx"): env must be an array of {name, value} pairs of strings',
      [{ "name" => "fx", "command" => "ruby", "env" => [{ "name" => "A" }] }] => 'mcpServers[0] ("fx"): env must be an array of {name, value} pairs of strings',
      [{ "name" => "fx", "command" => "ruby", "env" => [{ "name" => "A", "value" => 1 }] }] => 'mcpServers[0] ("fx"): env must be an array of {name, value} pairs of strings',
      [{ "type" => "http", "name" => "r" }] => 'mcpServers[0] ("r"): an http server needs a "url" (a string)',
      [{ "type" => "http", "name" => "r", "url" => "https://x", "headers" => [["A", "b"]] }] => 'mcpServers[0] ("r"): headers must be an array of {name, value} pairs of strings',
      [{ "type" => "grpc", "name" => "g" }] => 'mcpServers[0] ("g"): type must be one of stdio, http, sse, acp, got "grpc"',
      [{ "type" => 7, "name" => "g" }] => 'mcpServers[0] ("g"): type must be one of stdio, http, sse, acp, got 7',
      [{ "name" => "fx", "command" => "ruby" }, { "name" => "ok", "command" => "ruby" }, { "name" => "fx", "command" => "ruby" }] => 'mcpServers names "fx" twice',
      [{ "name" => "ok", "command" => "ruby" }, { "name" => "bad" }] => 'mcpServers[1] ("bad"): a stdio server needs a "command" (a string)',
    }
    cases.each do |entries, sentence|
      error = assert_raises(ArgumentError, entries.inspect) { from_acp(entries) }
      assert_equal sentence, error.message
    end
  end
end
