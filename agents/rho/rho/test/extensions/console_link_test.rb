require "test_helper"
require "support/daemon_harness"

# The CLI locates the public login page through its own authenticated route.
# Browser authentication belongs to core OAuth and never rides in this URL.
class ConsoleLinkExtensionTest < Minitest::Test
  include RhoTest::DaemonHarness

  WITHOUT_CONSOLE_LINK = Rho::Extensions::DEFAULT_EXTENSIONS - [Rho::Extensions::ConsoleLink]

  def boot(extensions: [Rho::Extensions::ConsoleLink], config: agent_mode, **options) = super(extensions:, config:, **options)

  def test_it_registers_the_page_location_and_the_console_verb
    api = Rho::Extensions::Api.new(host: RhoTest.host, extension_name: "rho.console_link", source: "<test>")
    Rho::Extensions::ConsoleLink.register(api)

    assert_equal [["GET", "/console", :bearer]],
      api.routes.map { |route| [route.method, route.path, route.auth] }
    assert_equal ["console"], api.commands.map(&:name)
    assert_empty api.tools
    assert_empty api.daemon_hooks
  end

  def test_without_the_extension_the_page_and_core_login_remain_available
    daemon = boot(webui_root: console_bundle, extensions: WITHOUT_CONSOLE_LINK, config: Rho::Config.from_hash({}))

    assert_predicate daemon, :page?
    assert_equal "200", request(daemon, :get, "/").code
    assert_equal "200", request(daemon, :get, "/auth/status").code
    refute_includes daemon.routes.entries.map(&:path), "/console"
  end

  def test_locating_the_page_requires_local_control_but_returns_no_credential
    daemon = boot(webui_root: console_bundle)

    assert_equal "401", request(daemon, :get, "/console").code
    response = request(daemon, :get, "/console", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    assert_equal({ "url" => daemon.endpoint }, JSON.parse(response.body))
    refute_includes response.body, bearer(daemon)
  end

  def test_the_page_location_uses_the_configured_browser_url
    daemon = boot(webui_root: console_bundle, config: agent_mode("public_url" => "http://10.0.0.115:7777"))

    response = request(daemon, :get, "/console", token: bearer(daemon))
    assert_equal "http://10.0.0.115:7777", JSON.parse(response.body).fetch("url")
  end

  def test_a_daemon_without_a_page_refuses_the_console_link
    daemon = boot(config: agent_mode("api_only" => true), webui_root: console_bundle)

    response = request(daemon, :get, "/console", token: bearer(daemon))
    assert_equal "409", response.code
    assert_equal "page_not_served", JSON.parse(response.body).dig("error", "code")
  end

  def test_a_claimed_path_with_the_wrong_method_is_not_the_page
    daemon = boot(webui_root: console_bundle)

    response = request(daemon, :post, "/console", token: bearer(daemon), body: {})
    assert_equal "404", response.code
    refute_includes response.body, "<p>rho</p>"
    assert_equal "200", request(daemon, :get, "/an-unclaimed-deep-link").code
  end
end
