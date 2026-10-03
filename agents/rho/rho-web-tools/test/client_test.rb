require "test_helper"
require "socket"

# THE CLIENT OVER A REAL LOOPBACK SERVER: the page,
# the same-site chain with a bodied 302 that never reaches the page, the
# cross-site halt and the bound with their sentences, a relative Location,
# a bare 3xx as data, the header refusal and the streamed cap by the
# CLIENT's own count, the deadline over `/slow` and over a chain, a
# resolver nobody answers, the connect refusal, the TLS wrap, a cancel
# during `/slow` returning within a second, a 404 as data, the private
# default on an address AND on a name, the five sentinels under the lift,
# and the headers the fixture received.
class ClientTest < Minitest::Test
  include WebToolsTest::Helpers

  def setup
    @app = WebToolsTest::FixtureApp.new
    @site = serve(@app)
    @other_app = WebToolsTest::FixtureApp.new
    @other = serve(@other_app)
    @app.other = @other
  end

  def teardown = halt_servers

  def client(**options) = Rho::WebTools::Client.new(allow_private_network: true, **options)

  def within_context(&) = Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new, &)

  # httpx's own parsing of a response header other than Location raises
  # URI::InvalidURIError; the client keeps Alt-Svc, the one such header
  # known, away from httpx, so this double raises from the call site httpx
  # reads that header at — on the calling thread, inside the block only.
  module RefusedHeader
    def emit(request, response)
      raise URI::InvalidURIError, "bad URI (is not URI?): \"https://exa mple:443\"" if Thread.current[:refused_header]

      super
    end
  end
  HTTPX::AltSvc.singleton_class.prepend(RefusedHeader)

  def refusing_a_header
    Thread.current[:refused_header] = true
    yield
  ensure
    Thread.current[:refused_header] = nil
  end

  def test_the_page_arrives_whole_with_its_type_charset_and_count
    page = client.get("#{@site}/page.html")
    assert_equal 200, page.status
    assert_equal "text/html", page.media_type
    assert_equal "utf-8", page.charset
    assert_equal WebToolsTest::FixtureApp::PAGE.bytesize, page.bytes
    assert_equal WebToolsTest::FixtureApp::PAGE.b, page.body
    assert_equal "#{@site}/page.html", page.final_url
    assert_equal 0, page.redirects
    refute_predicate page, :error?
    refute_predicate page, :redirect?
  end

  # THE 3XX BODY NEVER REACHES THE PAGE: `/same` is a 302 WITH an HTML body
  # ("Redirecting…"); the stream plugin hands every hop's chunks to the
  # root's one stream, and only the final response's are kept.
  def test_a_same_site_redirect_is_followed_and_the_hops_body_is_dropped
    direct = client.get("#{@site}/page.html")
    page = client.get("#{@site}/same")
    assert_equal 200, page.status
    assert_equal 1, page.redirects
    assert_equal "#{@site}/page.html", page.final_url
    assert_equal "#{@site}/same", page.url
    assert_equal direct.body, page.body, "the 302's own body reached the accumulator"
    refute_includes page.body, "Redirecting"
  end

  def test_a_relative_location_reaches_the_rule_absolute_and_is_followed
    page = client.get("#{@site}/relative")
    assert_equal 200, page.status
    assert_equal "#{@site}/page.html", page.final_url
  end

  def test_a_cross_site_redirect_is_reported_with_its_sentence_not_followed
    error = assert_raises(Rho::WebTools::Redirected) { client.get("#{@site}/away") }
    assert_equal "redirect: #{@site}/away → #{@other}/page.html (302); web_fetch follows redirects on the same " \
                 "site only — call web_fetch with the new url to follow it", error.message
    assert_equal 302, error.status
    assert_equal "#{@other}/page.html", error.location
    assert_empty @other_app.seen, "the other site was reached"
  end

  # A chain halts against the ORIGINAL: hop one is same-site and followed,
  # hop two names the other site and is reported with the original URL.
  def test_a_chain_is_judged_against_the_original_url
    error = assert_raises(Rho::WebTools::Redirected) { client.get("#{@site}/hop") }
    assert_match(/\Aredirect: #{Regexp.escape(@site)}\/hop → #{Regexp.escape(@other)}\/page\.html \(302\);/, error.message)
  end

  def test_the_redirect_bound_is_three_and_its_sentence_names_it
    error = assert_raises(Rho::WebTools::Redirected) { client.get("#{@site}/loop") }
    assert_equal "#{@site}/loop redirected 3 times without answering; web_fetch follows at most 3 redirects",
      error.message
    assert_equal 4, @app.seen.length, "the first request and three hops, no more"
  end

  # A LOCATION NO PARSER TAKES comes from a server this tool does not
  # control: httpx parses it before `redirect_on` is asked. It is a redirect
  # not followed, the header shown escaped in the sentence (so raw UTF-8
  # cannot break the sentence's own encoding) and absent from `location`,
  # which names only a URL a caller could fetch.
  def test_a_malformed_location_is_a_redirect_not_followed_named_in_its_sentence
    { 0 => '"http://exa mple.com/x"', 1 => '"http://[not-an-ip]/"', 2 => '"http://x/K\xC3\xB6ln"' }.each do |index, shown|
      url = "#{@site}/malformed/#{index}"
      error = assert_raises(Rho::WebTools::Redirected, url) { client.get(url) }
      assert_equal "redirect: #{url} → #{shown} (302); the server's Location is not a valid URL, so web_fetch " \
                   "cannot follow it", error.message
      assert_equal 302, error.status
      assert_nil error.location
    end
  end

  # PAST THE BOUND the plugin returns the fourth 3xx unparsed, and the
  # client's own parse (to pick the halting sentence) meets the header.
  def test_a_malformed_location_on_the_answer_that_spends_the_bound_takes_the_same_sentence
    error = assert_raises(Rho::WebTools::Redirected) { client.get("#{@site}/spent/3") }
    assert_equal "redirect: #{@site}/spent/3 → \"http://exa mple.com/x\" (302); the server's Location is not a " \
                 "valid URL, so web_fetch cannot follow it", error.message
    assert_equal 302, error.status
    assert_equal 4, @app.seen.length, "the first request and three hops, no more"
  end

  # A HUGE LOCATION reaches the model shortened by the status line's own
  # rule, and `location` stays nil: a shortened URL is not one a caller
  # could fetch. Nothing else bounds a header's size before the model.
  # A LONG TARGET A SERVER STILL ACCEPTS IS ONE THE MODEL CAN FOLLOW: a
  # presigned URL runs to thousands of bytes, so the sentence and the typed
  # field carry it whole up to the common request-line limit.
  def test_a_long_cross_site_location_a_server_would_accept_is_carried_whole
    target = "#{@other}/#{"a" * WebToolsTest::FixtureApp::LONG_PATH_BYTES}"
    cross = assert_raises(Rho::WebTools::Redirected) { client.get("#{@site}/long/cross") }
    assert_equal target, cross.location, "the model can call web_fetch with it"
    assert_includes cross.message, target
  end

  def test_a_huge_location_is_shortened_in_the_sentence_and_absent_from_location
    cross = assert_raises(Rho::WebTools::Redirected) { client.get("#{@site}/huge/cross") }
    assert_operator cross.message.bytesize, :<, Rho::WebTools::Client::URL_ACTIONABLE_BYTES + 512
    assert_equal "redirect: #{@site}/huge/cross → " \
                 "#{Rho::WebTools.shorten("#{@other}/#{"a" * WebToolsTest::FixtureApp::HUGE_PATH_BYTES}", Rho::WebTools::Client::URL_ACTIONABLE_BYTES)} (302); web_fetch " \
                 "follows redirects on the same site only — call web_fetch with the new url to follow it", cross.message
    assert_equal 302, cross.status
    assert_nil cross.location

    malformed = assert_raises(Rho::WebTools::Redirected) { client.get("#{@site}/huge/malformed") }
    assert_operator malformed.message.bytesize, :<, 1024
    dumped = WebToolsTest::FixtureApp::HUGE_MALFORMED.b.dump
    assert_equal "redirect: #{@site}/huge/malformed → #{Rho::WebTools.shorten(dumped, 512)} (302); the server's Location " \
                 "is not a valid URL, so web_fetch cannot follow it", malformed.message
    assert_nil malformed.location
  end

  # AN ALT-SVC HEADER IS NEVER READ: httpx's parser spins inside the
  # selector's callback, where neither the deadline nor the cancel watch
  # runs, or raises URI::InvalidURIError. Each fetch runs on a thread of its
  # own, so a spin fails the test instead of hanging the suite.
  def test_an_alt_svc_header_is_ignored_on_a_page_and_on_a_followed_hop
    WebToolsTest::FixtureApp::ALT_SVC.each_index do |index|
      { "#{@site}/alt-svc/#{index}" => 0, "#{@site}/alt-svc-hop/#{index}" => 1 }.each do |url, redirects|
        worker = Thread.new { client(total_timeout: 2).get(url) }
        assert worker.join(5), "#{url} did not return within 5s: httpx is still parsing its Alt-Svc"
        page = worker.value
        assert_equal 200, page.status, url
        assert_equal redirects, page.redirects, url
      ensure
        worker&.kill
      end
    end
  end

  # A TRAILER carries the header too, and httpx reads it the same way.
  # puma writes no trailers, so a raw socket answers one chunked response
  # with `Alt-Svc: garbage` after its body.
  def test_an_alt_svc_trailer_is_ignored
    server = TCPServer.new("127.0.0.1", 0)
    answering = Thread.new do
      socket = server.accept
      socket.readpartial(4096)
      socket.write("HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ntransfer-encoding: chunked\r\ntrailer: alt-svc\r\n\r\n" \
                   "5\r\nhello\r\n0\r\nalt-svc: garbage\r\n\r\n")
      socket.close
    end
    worker = Thread.new { client(total_timeout: 2).get("http://127.0.0.1:#{server.addr[1]}/") }
    assert worker.join(5), "the fetch did not return within 5s: httpx is still parsing the Alt-Svc trailer"
    assert_equal "hello".b, worker.value.body
  ensure
    worker&.kill
    answering&.kill
    server&.close
  end

  # A HEADER HTTPX REFUSES THAT IS NOT THE LOCATION: the answer is
  # unreachable data, never a malformed-Location refusal of a Location
  # that parses, never a crash on a response that named none.
  def test_a_header_httpx_cannot_parse_is_unreachable_not_a_malformed_location
    refusing_a_header do
      ["#{@site}/notes.txt", "#{@site}/relative"].each do |url|
        error = assert_raises(Rho::WebTools::Unreachable, url) { client.get(url) }
        assert_equal "127.0.0.1 sent a response header web_fetch cannot parse", error.message
      end
    end
  end

  # A SAME-SITE HOP WITH A RETRY-AFTER that is neither seconds nor an HTTP
  # date: httpx parses it after building the next request and before
  # sending it, so the redirect is reported with the URL it names.
  def test_a_same_site_redirect_with_a_malformed_retry_after_is_reported_not_followed
    error = assert_raises(Rho::WebTools::Redirected) { client.get("#{@site}/retry-after") }
    assert_equal "redirect: #{@site}/retry-after → #{@site}/notes.txt; the server's Retry-After is not a number of " \
                 "seconds or an HTTP date, so web_fetch cannot follow it — call web_fetch with the new url to read it",
      error.message
    assert_nil error.status
    assert_equal "#{@site}/notes.txt", error.location
    assert_equal 1, @app.seen.length, "the redirect was followed"
  end

  def test_a_3xx_without_a_location_is_data_with_its_body
    page = client.get("#{@site}/gone")
    assert_equal 300, page.status
    assert_predicate page, :redirect?
    assert_equal "Nothing here to choose from.\nsecond line".b, page.body
  end

  def test_a_4xx_is_data_with_the_first_512_bytes_and_its_status
    page = client.get("#{@site}/missing")
    assert_equal 404, page.status
    assert_predicate page, :error?
    assert_equal "no such page\nsecond line".b, page.body
    assert_equal "text/plain", page.media_type
  end

  # THE HEADER REFUSAL: refused at the first chunk, before a second is on
  # the wire — the CLIENT counted nothing, and it returned at once.
  def test_a_content_length_over_the_cap_is_refused_with_nothing_counted
    error = nil
    seconds = elapsed { error = assert_raises(Rho::WebTools::TooLarge) { client.get("#{@site}/big") } }
    assert_equal "127.0.0.1 answered Content-Length 6.0MB; web_fetch reads at most 5.0MB", error.message
    assert_equal 0, error.bytes
    assert_operator seconds, :<, 2
  end

  # THE STREAMED CAP: no Content-Length, six megabytes in chunks; the
  # client stops at the cap plus at most one chunk, and does not wait for
  # the rest.
  def test_a_streamed_body_over_the_cap_is_refused_by_the_clients_own_count
    error = nil
    seconds = elapsed { error = assert_raises(Rho::WebTools::TooLarge) { client.get("#{@site}/stream") } }
    assert_equal "127.0.0.1 sent more than 5.0MB; web_fetch reads at most 5.0MB", error.message
    assert_operator error.bytes, :>, Rho::WebTools::Client::WIRE_CAP
    assert_operator error.bytes, :<=, Rho::WebTools::Client::WIRE_CAP + 65_536 * 2
    assert_operator seconds, :<, 10
  end

  def test_the_deadline_wraps_a_slow_answer_naming_the_host_and_the_seconds
    error = nil
    seconds = elapsed { error = assert_raises(Rho::WebTools::Unreachable) { client(total_timeout: 2).get("#{@site}/slow") } }
    assert_equal "127.0.0.1 did not answer within 2s", error.message
    assert_operator seconds, :<, 4
  end

  # THE DEADLINE OVER A CHAIN: a redirect hop is inside the same
  # `receive_requests`, so one timer walls the whole chain.
  def test_the_deadline_is_one_wall_over_a_redirect_chain
    error = nil
    seconds = elapsed { error = assert_raises(Rho::WebTools::Unreachable) { client(total_timeout: 2).get("#{@site}/same-slow") } }
    assert_equal "127.0.0.1 did not answer within 2s", error.message
    assert_operator seconds, :<, 4
  end

  # A RESOLVER STALL: a nameserver that never answers, under the injected
  # deadline — the wall is armed before resolve, so it cannot outlive it.
  def test_a_resolver_nobody_answers_meets_the_deadline
    socket = UDPSocket.new
    socket.bind("127.0.0.1", 0)
    port = socket.addr[1]
    stalled = client(total_timeout: 2, resolver_options: { nameserver: [["127.0.0.1", port]], timeouts: [30] })
    error = nil
    seconds = elapsed { error = assert_raises(Rho::WebTools::Unreachable) { stalled.get("http://nobody.example.test/") } }
    assert_match(/\Anobody\.example\.test (did not answer within 2s|could not be resolved)\z/, error.message)
    assert_operator seconds, :<, 4
  ensure
    socket&.close
  end

  def test_a_refused_connection_is_one_sentence_naming_the_host
    closed = TCPServer.new("127.0.0.1", 0)
    port = closed.addr[1]
    closed.close
    error = assert_raises(Rho::WebTools::Unreachable) { client.get("http://127.0.0.1:#{port}/") }
    assert_equal "127.0.0.1 refused the connection", error.message
  end

  def test_a_failed_tls_handshake_is_wrapped
    error = assert_raises(Rho::WebTools::Unreachable) { client.get(@site.sub("http://", "https://") + "/page.html") }
    assert_match(/\A127\.0\.0\.1 (failed the TLS handshake|could not be reached)/, error.message)
    refute_match(/page\.html/, error.message)
  end

  # THE CANCEL WAKE: the worker is blocked in a read nobody answers; the
  # runner cancels the context from another thread; the request returns
  # within a second as the context's own `Cancelled`.
  def test_a_cancel_during_a_blocked_read_returns_within_a_second
    context = Rho::Runner::ExecutionContext.new
    outcome = nil
    worker = Thread.new do
      Rho::Runner::ExecutionContext.with(context) do
        client.get("#{@site}/slow")
      rescue Exception => error # rubocop:disable Lint/RescueException
        outcome = error
      end
    end
    sleep 0.3
    seconds = elapsed do
      context.cancel
      worker.join(3)
    end
    refute_predicate worker, :alive?, "the request did not return"
    assert_kind_of Rho::Runner::ExecutionContext::Cancelled, outcome
    assert_operator seconds, :<, 1
  end

  def test_the_default_refuses_a_loopback_address_and_a_loopback_name_before_any_socket
    strict = Rho::WebTools::Client.new
    before = @app.seen.length
    error = assert_raises(Rho::WebTools::Refused) { strict.get("#{@site}/page.html") }
    assert_equal strict.private_sentence("127.0.0.1"), error.message
    assert_equal "127.0.0.1 resolves to a private or reserved address; web_fetch reaches public hosts only " \
                 "(settings.json \"web\": {\"allow_private_network\": true} lifts loopback and RFC 1918)", error.message
    error = assert_raises(Rho::WebTools::Refused) { strict.get(@site.sub("127.0.0.1", "localhost") + "/page.html") }
    assert_equal strict.private_sentence("localhost"), error.message
    assert_equal before, @app.seen.length, "a socket was opened"
  end

  # THE LIFT IS LOOPBACK AND RFC 1918 ONLY: every metadata endpoint hermes
  # keeps on its always-blocked floor falls in a range the plugin still
  # refuses — link-local, CGNAT, unique-local — pinned by name.
  def test_the_five_sentinels_stay_refused_under_the_lift
    %w[169.254.169.254 169.254.170.2 169.254.169.253 100.100.100.200 [fd00:ec2::254]].each do |host|
      error = assert_raises(Rho::WebTools::Refused, host) { client.get("http://#{host}/latest/meta-data/") }
      assert_includes error.message, "#{host.delete("[]")} resolves to a private or reserved address"
      assert_equal :private_address, error.reason
    end
  end

  def test_the_headers_are_honest_and_carry_no_language
    client.get("#{@site}/notes.txt")
    request = @app.seen.last
    assert_equal "rho-web-tools/#{Rho::WebTools::VERSION}", request["HTTP_USER_AGENT"]
    assert_equal "text/markdown, text/html, */*", request["HTTP_ACCEPT"]
    refute request.key?("HTTP_ACCEPT_LANGUAGE")
    refute request.key?("HTTP_AUTHORIZATION")
    refute request.key?("HTTP_COOKIE")
  end

  # THE RULE, before a socket: each refusal one sentence,
  # the credentials sentence naming nothing of the userinfo.
  def test_the_url_rule_refuses_what_a_rule_could_not_judge
    rule = Rho::WebTools::UrlRule
    assert_equal rule::NOT_A_URL, assert_raises(Rho::WebTools::Refused) { rule.parse("http://x/Köln") }.message
    assert_equal rule::NOT_A_URL, assert_raises(Rho::WebTools::Refused) { rule.parse("http://x/a b") }.message
    assert_equal rule::SCHEME, assert_raises(Rho::WebTools::Refused) { rule.parse("ftp://x/") }.message
    assert_equal rule::SCHEME, assert_raises(Rho::WebTools::Refused) { rule.parse("nonsense") }.message
    error = assert_raises(Rho::WebTools::Refused) { rule.parse("http://secret-user:secret-pass@127.0.0.1/") }
    assert_equal rule::CREDENTIALS, error.message
    refute_match(/secret/, error.message)
    { "CORP.INTERNAL" => "http://CORP.INTERNAL/", "corp.internal." => "http://corp.internal./",
      "c%6frp.internal" => "http://c%6frp.internal/", "0x0a000005" => "http://0x0a000005/",
      "167772165" => "http://167772165/", "10.0.5" => "http://10.0.5/", "010.0.0.5" => "http://010.0.0.5/",
      "" => "http:///x" }.each do |host, url|
      error = assert_raises(Rho::WebTools::Refused, url) { rule.parse(url) }
      assert_equal rule.not_canonical(host), error.message
      assert_equal :url, error.reason
    end
    assert_equal "url host \"CORP.INTERNAL\" is not canonical; write it in lowercase ASCII without a trailing dot, " \
                 "an IPv4 address as four dotted decimals", rule.not_canonical("CORP.INTERNAL")
    assert_equal "docs.ruby-lang.org", rule.parse("https://docs.ruby-lang.org/en/master/String.html").host
    assert_equal "10.0.0.5", rule.parse("http://10.0.0.5:8080/").host
    assert_equal "[fd00:ec2::254]", rule.parse("http://[fd00:ec2::254]/").host
    assert_equal "abc.de", rule.parse("http://abc.de/").host
  end

  # `same_site?` against the ORIGINAL: the scheme, the port, one `www.`,
  # and no userinfo on the target — the three-hop `a → www.a → a:8443`.
  def test_same_site_strips_one_www_and_holds_scheme_and_port
    rule = Rho::WebTools::UrlRule
    a = URI.parse("https://a.example/x")
    assert rule.same_site?(a, URI.parse("https://www.a.example/y"))
    assert rule.same_site?(a, URI.parse("https://a.example/z?q=1"))
    refute rule.same_site?(a, URI.parse("https://a.example:8443/"))
    refute rule.same_site?(a, URI.parse("http://a.example/"))
    refute rule.same_site?(a, URI.parse("https://b.example/"))
    refute rule.same_site?(a, URI.parse("https://u:p@a.example/"))
  end
end
