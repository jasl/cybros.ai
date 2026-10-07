require "test_helper"

# THE ROW GRAMMAR of `settings.json#acp_agents`:
# rho-mcp's shape, the secrets trio the runner's (`Rho::Runner::Secrets`,
# `Redact`), faults per row, only a table that is not rows refusing the
# extension.
class SettingsTest < Minitest::Test
  Settings = Rho::AcpClient::Settings

  def raw(**extra)
    { "command" => "opencode", "args" => ["acp"], "description" => "OpenCode on OpenRouter" }.merge(extra)
  end

  def parse(table, env: {}) = Settings.parse(table, env: env)

  def test_a_row_parses_with_its_defaults
    row = parse({ "opencode" => raw }).fetch(0)
    assert_equal "opencode", row.key
    assert_equal "opencode", row.command
    assert_equal ["acp"], row.args
    assert_equal({}, row.env)
    assert_equal "OpenCode on OpenRouter", row.description
    assert_equal "allow", row.permissions
    assert_predicate row, :allow?
    assert_equal Settings::DEFAULT_TIMEOUT_MS, row.timeout_ms
    assert_nil row.auth_method
    assert_nil row.model
    assert_predicate row, :enabled?
    assert_empty row.secrets
    assert_equal "opencode acp", row.launch
    refute_predicate row, :fault?
  end

  def test_every_key_is_read
    row = parse({ "rho-b" => raw("command" => "/opt/rho-b/bin/rho", "args" => ["acp", "--mode", "ask"],
      "env" => { "RHO_HOME" => "/home/me/.rho-b" }, "permissions" => "reject", "timeout_ms" => 1000,
      "auth_method" => "nexus", "model" => "test-model", "enabled" => false) }).fetch(0)
    assert_equal ["acp", "--mode", "ask"], row.args
    assert_equal({ "RHO_HOME" => "/home/me/.rho-b" }, row.env)
    assert_equal "reject", row.permissions
    refute_predicate row, :allow?
    assert_equal 1000, row.timeout_ms
    assert_equal "nexus", row.auth_method
    assert_equal "test-model", row.model
    refute_predicate row, :enabled?
  end

  # `${NAME}` expanded ONCE from the daemon's environment, every expansion
  # a secret; a literal under a credential-shaped key a secret too; a
  # short literal not; an unset name the row's fault naming the KEY.
  def test_expansion_and_the_secrets
    env = { "OPENROUTER_API_KEY" => RhoAcpClientTest::SECRET }
    row = parse({ "a" => raw("env" => { "OPENROUTER_API_KEY" => "${OPENROUTER_API_KEY}", "GH_TOKEN" => "ghp_literal_0123456789",
                                          "PORT" => "8080", "DEBUG_KEY" => "1" }) }, env: env).fetch(0)
    assert_equal RhoAcpClientTest::SECRET, row.env.fetch("OPENROUTER_API_KEY")
    assert_equal [RhoAcpClientTest::SECRET, "ghp_literal_0123456789"], row.secrets
    redact = Rho::Runner::Redact.new(row.secrets)
    assert_equal "key=••• token=••• port=8080", redact.call("key=#{RhoAcpClientTest::SECRET} token=ghp_literal_0123456789 port=8080")

    fault = parse({ "a" => raw("env" => { "X" => "${NOPE}" }) }, env: env).fetch(0)
    assert_predicate fault, :fault?
    assert_equal 'acp agent "a": env.X names ${NOPE}, which is not set in the daemon\'s environment', fault.sentence
    refute_includes fault.sentence, RhoAcpClientTest::SECRET
  end

  def test_the_faults_are_per_row_and_name_the_row
    faults = parse({
      "no-command" => raw.except("command"),
      "no-description" => raw.except("description"),
      "bad-args" => raw("args" => "acp"),
      "bad-permissions" => raw("permissions" => "ask"),
      "bad-timeout" => raw("timeout_ms" => 0),
      "big-timeout" => raw("timeout_ms" => Rho::Runner::Extensions::Tool::MAX_TIMEOUT_MS + 1),
      "bad-enabled" => raw("enabled" => "yes"),
      "stranger" => raw("cwd" => "/tmp"),
      "bad-model" => raw("model" => 3),
      "bad-auth" => raw("auth_method" => ""),
      "bad-env" => raw("env" => { "X" => 1 }),
    })
    assert faults.all?(&:fault?), faults.inspect
    sentences = faults.to_h { |fault| [fault.key, fault.sentence] }
    assert_equal 'acp agent "no-command": a row needs a "command" (a string)', sentences.fetch("no-command")
    assert_equal 'acp agent "no-description": a row needs a "description" (your words for the roster; the model reads it)',
      sentences.fetch("no-description")
    assert_equal 'acp agent "bad-args": args must be an array of strings', sentences.fetch("bad-args")
    assert_equal 'acp agent "bad-permissions": permissions must be one of allow, reject, got "ask"', sentences.fetch("bad-permissions")
    assert_match(/timeout_ms must be a positive integer of milliseconds no greater than \d+, got 0/, sentences.fetch("bad-timeout"))
    assert_match(/timeout_ms must be a positive integer/, sentences.fetch("big-timeout"))
    assert_equal 'acp agent "bad-enabled": enabled must be true or false, got "yes"', sentences.fetch("bad-enabled")
    assert_equal 'acp agent "stranger": "cwd" is not a key of an agent row (the keys: ' \
                 "#{Settings::KEYS.join(", ")})", sentences.fetch("stranger")
    assert_equal 'acp agent "bad-model": model must be a string', sentences.fetch("bad-model")
    assert_equal 'acp agent "bad-auth": auth_method must be a non-empty string', sentences.fetch("bad-auth")
    assert_equal 'acp agent "bad-env": env.X must be a string', sentences.fetch("bad-env")
    # A fault answers what a row answers, so no caller probes.
    fault = faults.fetch(0)
    assert_predicate fault, :enabled?
    assert_nil fault.launch
    assert_equal({}, fault.env)
    assert_nil fault.description
  end

  def test_only_a_table_that_is_not_rows_refuses_the_extension
    error = assert_raises(Settings::Malformed) { parse([]) }
    assert_equal "ACP agents must be an object of objects", error.message
    error = assert_raises(Settings::Malformed) { parse({ "Bad Key" => raw }) }
    assert_match(/ACP agents names "Bad Key"; an agent key is lowercase letters, digits and single hyphens/, error.message)
    error = assert_raises(Settings::Malformed) { parse({ "a" => "opencode" }) }
    assert_equal "ACP agents[a] must be an object", error.message
  end
end
