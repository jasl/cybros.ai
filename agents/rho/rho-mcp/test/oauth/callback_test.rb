require "test_helper"
require "net/http"
require "stringio"
require "uri"

# THE LOOPBACK LISTENER: a real bound endpoint
# on 127.0.0.1 at a port of the OS's choosing (or the row's), `/callback`
# answering `[code, state, iss]`; a stray path 404 and the wait kept; an
# `error` answer kept on the listener — its `iss` beside it, for the
# verb's comparison — and reflected ESCAPED; the pasted line racing the
# browser; nil past an injectable deadline; `close`.
class OauthCallbackTest < Minitest::Test
  def setup
    @listeners = []
  end

  def teardown
    @listeners.each(&:close)
  end

  def bind_listener(**options)
    Rho::Mcp::Oauth::Callback.new(**options).bind.tap { |l| @listeners << l }
  end

  # The body read as UTF-8 by name (Net::HTTP answers bytes).
  def get(listener, path)
    Net::HTTP.get_response(URI("http://127.0.0.1:#{listener.port}#{path}")).tap { |r| r.body.force_encoding(Encoding::UTF_8) }
  end

  def test_the_redirect_uri_names_the_bound_port_and_the_callback_answers_the_three
    listener = bind_listener
    assert_operator listener.port, :>, 0
    assert_equal "http://127.0.0.1:#{listener.port}/callback", listener.redirect_uri
    stray = get(listener, "/favicon.ico")
    assert_equal "404", stray.code, "a stray path keeps the wait"
    response = get(listener, "/callback?code=c-1&state=s-1&iss=https%3A%2F%2Fas.example%2Foauth")
    assert_equal "200", response.code
    assert_includes response.body, "rho: you are signed in — you can close this tab"
    assert_equal ["c-1", "s-1", "https://as.example/oauth"], listener.wait
    refute_predicate listener, :timed_out?
    assert_nil listener.error
    assert_equal "https://as.example/oauth", listener.iss
  end

  def test_a_fixed_port_is_honoured
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr.fetch(1)
    probe.close
    listener = bind_listener(port: port)
    assert_equal port, listener.port
    assert_equal "http://127.0.0.1:#{port}/callback", listener.redirect_uri
  end

  def test_an_error_answer_is_kept_on_the_listener_and_reflected_escaped
    listener = bind_listener
    response = get(listener, "/callback?error=access_denied&error_description=%3Cscript%3Ealert(1)%3C%2Fscript%3E&state=s-1" \
                             "&iss=https%3A%2F%2Fas.example%2Fother")
    assert_equal "200", response.code
    refute_includes response.body, "<script>"
    assert_includes response.body, "rho: the authorization server answered access_denied: &lt;script&gt;alert(1)&lt;/script&gt; — you can close this tab"
    assert_equal [nil, "s-1", "https://as.example/other"], listener.wait
    assert_equal "access_denied", listener.error
    assert_equal "<script>alert(1)</script>", listener.error_description
    assert_equal "https://as.example/other", listener.iss, "the iss is kept beside the error, for the verb to compare first"
  end

  def test_nil_past_the_deadline
    listener = bind_listener(seconds: 0.2)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_nil listener.wait
    assert_predicate listener, :timed_out?
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  end

  def test_a_pasted_redirect_url_races_the_browser_and_is_read_like_the_browsers
    listener = bind_listener
    paste = StringIO.new("http://127.0.0.1:1/callback?code=c-2&state=s-2&iss=https%3A%2F%2Fas.example%2Foauth\n")
    assert_equal ["c-2", "s-2", "https://as.example/oauth"], listener.wait(paste: paste)
    listener = bind_listener
    paste = StringIO.new("http://127.0.0.1:1/callback?error=access_denied&error_description=no&state=s-3&iss=https%3A%2F%2Fas.example%2Fother\n")
    assert_equal [nil, "s-3", "https://as.example/other"], listener.wait(paste: paste)
    assert_equal ["access_denied", "no", "https://as.example/other"], [listener.error, listener.error_description, listener.iss]
  end

  def test_the_browser_wins_when_stdin_is_silent
    listener = bind_listener
    reader, writer = IO.pipe
    get(listener, "/callback?code=c-4&state=s-4")
    assert_equal ["c-4", "s-4", nil], listener.wait(paste: reader)
  ensure
    writer&.close
    reader&.close
  end

  def test_close_releases_the_port
    listener = bind_listener
    port = listener.port
    listener.close
    @listeners.delete(listener)
    assert_raises(Errno::ECONNREFUSED) { Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/callback")) }
  end
end
