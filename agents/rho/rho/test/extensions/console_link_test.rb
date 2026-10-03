require "test_helper"
require "support/daemon_harness"

# THE DOOR TO THE PAGE IS AN EXTENSION'S, AND THE PAGE IS NOT: loaded alone it mints and redeems the one-shot
# code that carries the bearer into a browser; unloaded, the daemon still
# serves its bundle and the doors are simply not there.
class ConsoleLinkExtensionTest < Minitest::Test
  include RhoTest::DaemonHarness

  WITHOUT_CONSOLE_LINK = Rho::Extensions::DEFAULT_EXTENSIONS - [Rho::Extensions::ConsoleLink]

  def boot(extensions: [Rho::Extensions::ConsoleLink], config: agent_mode, **options) = super(extensions:, config:, **options)

  def test_it_registers_the_two_doors_and_the_one_verb
    api = Rho::Extensions::Api.new(host: RhoTest.host, extension_name: "rho.console_link", source: "<test>")
    Rho::Extensions::ConsoleLink.register(api)

    assert_equal [["POST", "/console/code", :bearer], ["POST", "/console/session", :none]],
      api.routes.map { |route| [route.method, route.path, route.auth] }
    assert_equal ["console"], api.commands.map(&:name)
    assert_empty api.tools
    assert_empty api.daemon_hooks
  end

  def test_without_the_extension_the_page_is_served_and_the_doors_are_gone
    daemon = boot(webui_root: console_bundle, extensions: WITHOUT_CONSOLE_LINK, config: Rho::Config.from_hash({}))

    assert_predicate daemon, :page?
    assert_equal "200", request(daemon, :get, "/").code, "the page is the core's"
    assert_equal "404", request(daemon, :post, "/console/code", token: bearer(daemon)).code
    assert_equal "404", redeem(daemon, "anything").code
    refute_includes daemon.routes.entries.map(&:path), "/console/session"
  end

  # Two daemons in one process mint from two tables: a code minted by one
  # is unknown to the other, so a link never crosses homes.
  def test_each_daemon_redeems_only_the_codes_it_minted
    first = boot(webui_root: console_bundle)
    second = boot(webui_root: console_bundle, root: File.join(@root, "second"))
    code = JSON.parse(request(first, :post, "/console/code", token: bearer(first)).body).fetch("code")

    assert_equal "401", redeem(second, code).code
    assert_equal "200", redeem(first, code).code
  end

  def redeem(daemon, code, header: "1", content_type: "application/json")
    uri = URI.join(daemon.endpoint, "/console/session")
    message = Net::HTTP::Post.new(uri)
    message["x-rho-console"] = header unless header.nil?
    message["Content-Type"] = content_type unless content_type.nil?
    message.body = JSON.generate(code: code)
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(message) }
  end

  # MINTING REQUIRES POSSESSION. That asymmetry is the whole security
  # argument: the code moves a bearer somebody already holds into a browser,
  # and is never a way to obtain one.
  def test_minting_a_console_code_demands_the_bearer
    daemon = boot(webui_root: console_bundle)

    assert_equal "401", request(daemon, :post, "/console/code").code
  end

  def test_a_minted_code_carries_the_link_the_home_and_its_expiry
    daemon = boot(webui_root: console_bundle)

    response = request(daemon, :post, "/console/code", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    document = JSON.parse(response.body)

    assert_equal "#{daemon.endpoint}##{Rho::Extensions::ConsoleLink::CONSOLE_FRAGMENT}=#{document.fetch("code")}",
      document.fetch("url")
    # The terminal that produced the link names the daemon it belongs to —
    # two RHO_HOMEs is otherwise an unexplained blank page.
    assert_equal daemon.home.root, document.fetch("home")
    assert_equal Rho::ConsoleCodes::TTL_SECONDS, document.fetch("expires_in_seconds")
  end

  def test_no_code_is_minted_for_a_daemon_that_serves_no_page
    daemon = boot(config: agent_mode("api_only" => true), webui_root: console_bundle)

    response = request(daemon, :post, "/console/code", token: bearer(daemon))
    assert_equal "409", response.code
    assert_equal "page_not_served", JSON.parse(response.body).dig("error", "code")
  end

  # ONE FACT PER ROUTE. `/healthz` already answers the versions, and the page
  # must be able to detect a mismatch BEFORE it spends its one-shot code.
  def test_redeeming_answers_the_bearer_and_nothing_else
    daemon = boot(webui_root: console_bundle)
    code = JSON.parse(request(daemon, :post, "/console/code", token: bearer(daemon)).body)
      .fetch("code")

    response = redeem(daemon, code)
    assert_equal "200", response.code, response.body
    document = JSON.parse(response.body)
    assert_equal ["bearer"], document.keys
    assert_equal bearer(daemon), document.fetch("bearer"), "the real credential, not a parallel one"
  end

  # NOT CORS-SAFELISTED, WHICH IS THE POINT: a page the operator merely
  # visited must preflight to reach this handler, and this router answers no
  # OPTIONS.
  def test_redeeming_without_the_console_header_is_refused_and_spends_nothing
    daemon = boot(webui_root: console_bundle)
    code = JSON.parse(request(daemon, :post, "/console/code", token: bearer(daemon)).body)
      .fetch("code")

    refused = redeem(daemon, code, header: nil)
    assert_equal "403", refused.code
    assert_equal "console_header_required", JSON.parse(refused.body).dig("error", "code")
    assert_equal "200", redeem(daemon, code).code, "the code must still be live"
  end

  def test_a_cors_simple_request_cannot_reach_the_redeem_logic
    daemon = boot(webui_root: console_bundle)
    code = JSON.parse(request(daemon, :post, "/console/code", token: bearer(daemon)).body)
      .fetch("code")

    refused = redeem(daemon, code, content_type: "text/plain")
    assert_equal "400", refused.code
    assert_equal "malformed_body", JSON.parse(refused.body).dig("error", "code")
    assert_equal "200", redeem(daemon, code).code, "and it spent nothing"
  end

  # THE ONLY THEFT SIGNAL THIS DESIGN HAS, so a replay must not read like a
  # stale bookmark.
  def test_a_replayed_code_says_it_was_used_rather_than_unknown
    daemon = boot(webui_root: console_bundle)
    code = JSON.parse(request(daemon, :post, "/console/code", token: bearer(daemon)).body)
      .fetch("code")
    redeem(daemon, code)

    response = redeem(daemon, code)
    assert_equal "409", response.code
    assert_equal "code_spent", JSON.parse(response.body).dig("error", "code")
    assert_match(/grants this host's shell/, JSON.parse(response.body).dig("error", "message"))
  end

  def test_an_unknown_code_says_to_mint_a_fresh_one
    daemon = boot(webui_root: console_bundle)

    response = redeem(daemon, "not-a-code")
    assert_equal "401", response.code
    assert_equal "code_unknown", JSON.parse(response.body).dig("error", "code")
    assert_match(/rho console/, JSON.parse(response.body).dig("error", "message"))
  end

  def test_redeeming_with_no_code_at_all_is_a_400
    daemon = boot(webui_root: console_bundle)

    assert_equal "400", redeem(daemon, nil).code
  end

  # A CLAIMED PATH IS NEVER A DEEP LINK: answering a probe of a control route
  # with 200 text/html is how a credential leaked out of an untested path.
  def test_a_get_on_a_claimed_path_is_not_the_page
    daemon = boot(webui_root: console_bundle)

    response = request(daemon, :get, "/console/session")
    assert_equal "405", response.code
    refute_includes response.body, "<p>rho</p>"
    assert_equal "200", request(daemon, :get, "/an-unclaimed-deep-link").code,
      "the deep-link fallback must survive the fix"
  end
end
