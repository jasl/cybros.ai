require "test_helper"

# THE DOOR IT COMES THROUGH is the loader's, over the handle a daemon hands
# an extension (`Rho::Extensions::Api` on `RhoTest.host`): the tool bound at registration where the host serves
# the runner address and an enabled row exists — tool-less otherwise —
# the two routes, the one verb, and the three hooks (`:host_ended`
# releases a conversation's children, `:shutdown` closes every child).
class ExtensionTest < Minitest::Test
  include RhoAcpClientTest::Helpers

  def teardown = Rho::AcpClient.reset!

  def load(table = nil, host: RhoTest.host)
    Rho::AcpClient.settings_table = table
    Rho::Runner::Extensions::Loader.call(gems: ["rho/acp-client"], api_class: Rho::Extensions::Api,
      api_options: { host: host })
  end

  def host(mode:)
    Rho::Extensions::Host.new(
      home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(Dir.tmpdir, "rho-acp-test-#{mode}")),
      log: nil, clock: -> { Time.now }, config: Rho::Config.from_hash({ "mode" => mode }), processes: nil
    )
  end

  def test_the_module_loads_with_its_version_and_name
    assert_kind_of Module, Rho::AcpClient
    assert_match(/\A\d+\.\d+\.\d+\z/, Rho::AcpClient::VERSION)
    assert_equal "rho.acp-client", Rho::AcpClient::NAME
    # The wire's gem loads through this one — its own `lib/rho/acp.rb`,
    # the one that carries a version, not another file at that path.
    assert_match(/\A\d+\.\d+\.\d+\z/, Rho::Acp::VERSION)
  end

  def test_the_feature_the_gemspec_names_resolves_to_this_module
    spec = Gem::Specification.load(File.join(RhoAcpClientTest::ROOT, "rho-acp-client.gemspec"))
    feature = spec.metadata.fetch(Rho::Runner::Extensions::Loader::GEM_METADATA_KEY)
    assert_equal "rho/acp-client", feature
    assert_same Rho::AcpClient, Rho::Runner::Extensions::Loader.require_feature(feature)
  end

  # NO ROW, NO TOOL: the extension loads clean — the verb, the
  # routes and the hooks stand — and announces nothing.
  def test_without_an_enabled_row_it_is_tool_less_but_keeps_its_verb_routes_and_hooks
    result = load({})
    assert_predicate result, :ok?, result.failures.inspect
    assert_empty result.registry.names
    api = result.committed.fetch(0)
    assert_equal "rho.acp-client", api.extension_name
    assert_predicate api, :restart_only?
    assert_empty api.tools
    assert_equal ["acp-agents"], api.commands.map(&:name)
    assert_equal [["GET", "/acp"], ["POST", "/acp/kill"]], api.routes.map { |route| [route.method, route.path] }
    assert_equal %i[shutdown], api.lifecycle.map(&:event)
    assert_equal %i[host_ended], api.daemon_hooks.map(&:event)
    assert_predicate api, :frozen?

    disabled = load({ "plain" => RhoAcpClientTest.raw_row("plain", "enabled" => false) })
    assert_predicate disabled, :ok?, disabled.failures.inspect
    assert_empty disabled.registry.names, "a disabled row contributes no tool"
  end

  # THE TOOL: one class, `delegate_agent`, its schema's `agent` the
  # enabled keys, its park the longest enabled clock, bash's profile.
  def test_an_enabled_row_registers_delegate_agent_on_the_runner_address
    result = load({
      "plain" => RhoAcpClientTest.raw_row("plain", "timeout_ms" => 5000),
      "sleepy" => RhoAcpClientTest.raw_row("sleep", "timeout_ms" => 9000),
      "off" => RhoAcpClientTest.raw_row("die", "enabled" => false),
      "broken" => { "command" => "" },
    })
    assert_predicate result, :ok?, result.failures.inspect
    assert_equal ["delegate_agent"], result.registry.names
    entry = result.registry.entries.fetch(0)
    assert_equal "rho.acp-client", entry.extension
    klass = result.committed.fetch(0).tools.fetch(0).klass
    assert_equal %w[plain sleepy], klass::SCHEMA.dig("properties", "agent", "enum")
    assert_equal 9000, klass::TIMEOUT_MS
    assert_equal Rho::Runner::Tools::Bash::EFFECT_PROFILE, klass::EFFECT_PROFILE
    assert klass::INTERNAL_CLAMP
    assert_includes klass::DESCRIPTION, "the plain fixture agent"
    assert_includes klass::DESCRIPTION, "the sleep fixture agent"
    refute_includes klass::DESCRIPTION, "the die fixture agent", "a disabled row is not offered"

    report = Rho::AcpClient.report
    agents = report.fetch("agents")
    assert_equal %w[plain sleepy off broken], agents.map { |agent| agent.fetch("key") }
    assert_equal %w[enabled enabled disabled down], agents.map { |agent| agent.fetch("state") }
    assert_match(/\Aconfig: acp agent "broken": a row needs a "command"/, agents.fetch(3).fetch("detail"))
    assert_empty report.fetch("sessions")
  end

  def test_registration_reads_the_resolved_plugin_configuration
    config = Rho::Config.from_hash({ "plugins" => { Rho::AcpClient::NAME => {
      "configuration" => { "agents" => { "plain" => RhoAcpClientTest.raw_row("plain") } },
    } } })
    current = RhoTest.host.with(config: config)
    result = load(nil, host: current)
    assert_predicate result, :ok?, result.failures.inspect
    assert_equal ["delegate_agent"], result.registry.names
    assert_equal ["plain"], result.registry.entries.fetch(0).klass::SCHEMA.fetch("properties").fetch("agent").fetch("enum")
  end

  # ONLY WHERE THE HOST SERVES THE RUNNER ADDRESS: an
  # agent-mode daemon keeps the verb and the routes and registers no tool.
  def test_an_agent_mode_host_gets_the_verb_and_no_tool
    result = load({ "plain" => RhoAcpClientTest.raw_row("plain") }, host: host(mode: "agent"))
    assert_predicate result, :ok?, result.failures.inspect
    assert_empty result.registry.names
    api = result.committed.fetch(0)
    assert_equal ["acp-agents"], api.commands.map(&:name)
    assert_equal 2, api.routes.length
  end

  # A TABLE THAT IS NOT ROWS refuses the extension (rho-mcp's rule one
  # level down); a bad ROW is listed down and costs the others nothing.
  def test_a_malformed_table_refuses_the_extension_by_sentence
    result = load("not rows")
    refute_predicate result, :ok?
    assert_match(/ACP agents must be an object of objects/, result.failures.fetch(0).message)
  end

  # `:shutdown` closes every child; `:host_ended` releases one
  # conversation's: both hooks reach the table.
  def test_the_hooks_reach_the_children_table
    result = load({ "plain" => RhoAcpClientTest.raw_row("plain") })
    api = result.committed.fetch(0)
    with_tool_env(conversation: "conv-a") do |env, _root|
      Rho::AcpClient.call({ "agent" => "plain", "prompt" => "one" }, env: env)
    end
    assert_equal 1, Rho::AcpClient.report.fetch("sessions").length
    pgid = Rho::AcpClient.report.fetch("sessions").fetch(0).fetch("pgid")
    api.daemon_hooks.find { |hook| hook.event == :host_ended }.handler.call("conv-a", "conversation")
    assert await { Rho::AcpClient.report.fetch("sessions").empty? ? true : nil }, "the conversation's child was not released"
    assert await { process_group_alive?(pgid) ? nil : true }, "the released child's group #{pgid} survived"

    with_tool_env(conversation: "conv-b") do |env, _root|
      Rho::AcpClient.call({ "agent" => "plain", "prompt" => "two" }, env: env)
    end
    pgid = Rho::AcpClient.report.fetch("sessions").fetch(0).fetch("pgid")
    api.lifecycle.find { |hook| hook.event == :shutdown }.handler.call
    assert_empty Rho::AcpClient.report.fetch("sessions")
    refute process_group_alive?(pgid), "shutdown left the group #{pgid}"
    error = assert_raises(Rho::AcpClient::Closed) do
      with_tool_env { |env, _root| Rho::AcpClient.call({ "agent" => "plain", "prompt" => "three" }, env: env) }
    end
    assert_equal "the acp client is shutting down", error.message
  end

  def test_reloading_rows_retires_changed_and_removed_children_but_preserves_unchanged_sessions
    plain = RhoAcpClientTest.raw_row("plain")
    load({ "keep" => plain, "change" => plain, "remove" => plain })
    with_tool_env(conversation: "conv-config") do |env, _root|
      %w[keep change remove].each do |agent|
        result = Rho::AcpClient.call({ "agent" => agent, "prompt" => "before" }, env: env)
        refute_predicate result, :is_error, result.content
      end
      before = Rho::AcpClient.report.fetch("sessions").to_h { |session| [session.fetch("agent"), session] }
      changed = load({ "keep" => plain, "change" => plain.merge("timeout_ms" => 8000) })
      assert_predicate changed, :ok?, changed.failures.inspect
      assert_equal [before.fetch("keep")], Rho::AcpClient.report.fetch("sessions")
      %w[change remove].each { |key| refute process_group_alive?(before.fetch(key).fetch("pgid")) }
      assert_equal %w[keep change], changed.committed.fetch(0).tools.fetch(0).klass::SCHEMA.dig("properties", "agent", "enum")

      kept = Rho::AcpClient.call({ "agent" => "keep", "session" => before.fetch("keep").fetch("session"), "prompt" => "after" }, env: env)
      refute_predicate kept, :is_error, kept.content
      assert_equal before.fetch("keep").fetch("session"), kept.structured_content.fetch("session")
      gone = Rho::AcpClient.call({ "agent" => "change", "session" => before.fetch("change").fetch("session"), "prompt" => "after" }, env: env)
      assert_predicate gone, :is_error
      assert_includes gone.content, "configuration changed"
      fresh = Rho::AcpClient.call({ "agent" => "change", "prompt" => "new settings" }, env: env)
      refute_predicate fresh, :is_error, fresh.content
      new_session = Rho::AcpClient::Children.session_document(fresh.structured_content.fetch("session"))
      refute_equal before.fetch("change").fetch("pid"), new_session.fetch("pid")
      assert_equal 8000, Rho::AcpClient.row("change").timeout_ms

      disabled = load({ "keep" => plain.merge("enabled" => false) })
      assert_predicate disabled, :ok?, disabled.failures.inspect
      assert_empty disabled.registry.names
      assert_empty Rho::AcpClient.report.fetch("sessions")
      refute process_group_alive?(before.fetch("keep").fetch("pgid"))
      refute process_group_alive?(new_session.fetch("pgid"))
    end
  end

  def test_a_removed_extension_can_be_registered_and_start_children_again
    table = { "plain" => RhoAcpClientTest.raw_row("plain") }
    first = load(table)
    first.committed.fetch(0).lifecycle.find { |hook| hook.event == :shutdown }.handler.call
    assert_predicate Rho::AcpClient::Children, :closed?
    readded = load(table)
    assert_predicate readded, :ok?, readded.failures.inspect
    refute_predicate Rho::AcpClient::Children, :closed?
    with_tool_env do |env, _root|
      result = Rho::AcpClient.call({ "agent" => "plain", "prompt" => "reopened" }, env: env)
      refute_predicate result, :is_error, result.content
      assert_includes result.content, "echo: reopened"
    end
  end
end
