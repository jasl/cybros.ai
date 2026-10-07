require "test_helper"

# THE CLI: `rho web fetch URL` prints the status line on
# stderr and the whole rendering on stdout — escaped by default, `--raw`
# byte for byte, a binary as its bytes — exit codes through the refusal,
# usage on no URL.
class CommandsTest < Minitest::Test
  include WebToolsTest::Helpers

  Cli = Struct.new(:out, :home, keyword_init: true)
  Home = Struct.new(:root, :settings_path, keyword_init: true)

  def setup
    @app = WebToolsTest::FixtureApp.new
    @site = serve(@app)
    @other = serve(WebToolsTest::FixtureApp.new)
    @app.other = @other
    Rho::WebTools.settings = { "allow_private_network" => true }
    Rho::WebTools.configure_markdown!
  end

  def teardown
    halt_servers
    Rho::WebTools.reset!
  end

  def cli = Cli.new(out: StringIO.new, home: Home.new(root: Dir.tmpdir, settings_path: "/nowhere/settings.json"))

  def fetch_verb(args, raw: false)
    c = cli
    err = nil
    _out, err = capture_io { Rho::WebTools::Commands.run(c, args, { raw: raw }) }
    [c.out.string, err]
  end

  def test_fetch_prints_the_status_line_on_stderr_and_the_whole_rendering_on_stdout
    out, err = fetch_verb(["fetch", "#{@site}/page.html"])
    assert_match(/\A#{Regexp.escape(@site)}\/page\.html — 200 text\/html; .* markdown; title: Fixture Page\n\z/, err)
    assert_includes out, "# Fixture Heading"
    refute_includes out, "STRIPPED_SCRIPT"
    rendering = Rho::WebTools::Render.markdown(WebToolsTest::FixtureApp::PAGE.b, charset: "utf-8")
    assert_equal rendering.text, out
  end

  # No truncation and no spill at the CLI: the whole long page, byte-equal
  # under `--raw` to the text the tool would spill.
  def test_raw_prints_the_long_page_whole_and_writes_no_spill
    out, _err = fetch_verb(["fetch", "#{@site}/long.html"], raw: true)
    assert_operator out.bytesize, :>, Rho::Runner::Truncation::DEFAULT_MAX_BYTES
    refute_includes out, "[Showing lines"
    assert_equal Rho::WebTools::Render.markdown(WebToolsTest::FixtureApp::LONG.b, charset: "utf-8").text, out
  end

  def test_the_default_escapes_what_a_model_would_not_see
    assert_equal "a\\u{200B}b\nc\\u{202E}d\\u{1B}[31m\tok", Rho::WebTools::Commands.escape("a​b\nc‮d\e[31m\tok")
    assert_equal "plain text — fine", Rho::WebTools::Commands.escape("plain text — fine")
  end

  def test_a_binary_answer_is_its_bytes_always_raw
    out, err = fetch_verb(["fetch", "#{@site}/pixel.png"])
    assert_equal WebToolsTest::FixtureApp::PNG, out.b
    assert_equal "#{@site}/pixel.png — 200 image/png; #{Rho::WebTools::Tools::Fetch.size(WebToolsTest::FixtureApp::PNG.bytesize)}\n", err
  end

  def test_a_refusal_is_the_models_sentence_as_the_error_the_cli_prints
    error = assert_raises(Rho::WebTools::Error) { fetch_verb(["fetch", "#{@site}/away"]) }
    assert_equal "redirect: #{@site}/away → #{@other}/page.html (302); web_fetch follows redirects on the same " \
                 "site only — call web_fetch with the new url to follow it", error.message
    error = assert_raises(Rho::WebTools::Error) { fetch_verb(["fetch", "ftp://x"]) }
    assert_equal Rho::WebTools::UrlRule::SCHEME, error.message
    error = assert_raises(Rho::WebTools::Error) { fetch_verb(["fetch", "#{@site}/missing"]) }
    assert_equal "#{@site}/missing answered 404 Not Found\n\nno such page\nsecond line", error.message
  end

  def test_no_url_prints_usage
    error = assert_raises(Rho::WebTools::Error) { fetch_verb(["fetch"]) }
    assert_equal "usage: rho web fetch URL", error.message
    error = assert_raises(Rho::WebTools::Error) { fetch_verb([]) }
    assert_equal "usage: rho web fetch URL", error.message
  end

  def test_the_verb_reads_the_settings_the_extension_judged
    Rho::WebTools.settings = {}
    error = assert_raises(Rho::WebTools::Error) { fetch_verb(["fetch", "#{@site}/page.html"]) }
    assert_equal Rho::WebTools::Client.new.private_sentence("127.0.0.1"), error.message
  end
end
