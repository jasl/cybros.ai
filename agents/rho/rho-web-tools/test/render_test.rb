require "test_helper"

# THE RENDER: the fixture HTML to markdown — the heading,
# the link, the image, the dropped script/style/noscript/svg, the title;
# a TWO-THREAD render of fenced code, both fenced (the module-state pin);
# the charset from the header, from the meta, and the scrub; the
# invisible strip; the content-type table row by row; and the S1 gate's
# number: the 5 MiB HTML cut at RENDER_INPUT_BYTES and rendered under the
# 15 s budget.
class RenderTest < Minitest::Test
  def setup = Rho::WebTools.configure_markdown!

  def page(body, media_type: "text/html", charset: nil)
    Rho::WebTools::Page.new(url: "http://x/", final_url: "http://x/", status: 200, media_type: media_type,
      charset: charset, body: body.b, bytes: body.bytesize, redirects: 0)
  end

  def test_the_fixture_page_renders_to_markdown_with_the_noise_dropped
    rendering = Rho::WebTools::Render.call(page(WebToolsTest::FixtureApp::PAGE, charset: "utf-8"))
    assert_equal :markdown, rendering.kind
    assert_equal "Fixture Page", rendering.title
    assert_nil rendering.cut
    text = rendering.text
    assert_includes text, "# Fixture Heading"
    assert_includes text, "[link text](/other)"
    assert_includes text, "![a red square](/pixel.png)"
    ["STRIPPED_SCRIPT", "STRIPPED_NOSCRIPT", "STRIPPED_SVG", "color: red"].each { |noise| refute_includes text, noise }
    refute_includes text, "​", "the zero-width space reached the model"
    assert_includes text, "The second paragraph carries a zero-width space."
    assert_equal Encoding::UTF_8, text.encoding
    assert_predicate text, :valid_encoding?
  end

  # THE MODULE-STATE PIN: `ReverseMarkdown.config` is written once and
  # `convert` takes no inline options, so a parallel fan of renders cannot
  # strip one another's fences.
  def test_two_threads_render_fenced_code_fenced
    html = "<html><body><p>before</p><pre><code>def a\n  1\nend</code></pre><p>after</p></body></html>"
    results = Array.new(4) do
      Thread.new { Array.new(25) { Rho::WebTools::Render.call(page(html)).text } }
    end.flat_map(&:value)
    assert_equal 1, results.uniq.length, "the renders diverged under a fan"
    assert_includes results.first, "```\ndef a\n  1\nend\n```"
  end

  def test_the_charset_comes_from_the_header_then_the_meta_then_utf8_with_a_scrub
    latin = "<html><head><title>H</title></head><body><p>na\xEFve</p></body></html>".b
    assert_includes Rho::WebTools::Render.call(page(latin, charset: "iso-8859-1")).text, "naïve"
    meta = "<html><head><meta charset=\"windows-1252\"></head><body><p>caf\xE9 \x93quoted\x94</p></body></html>".b
    assert_includes Rho::WebTools::Render.call(page(meta)).text, "café “quoted”"
    broken = "<html><body><p>bad \xFF byte</p></body></html>".b
    text = Rho::WebTools::Render.call(page(broken)).text
    assert_predicate text, :valid_encoding?
    assert_includes text, "bad"
    unknown = Rho::WebTools::Render.call(page("<html><body><p>ok</p></body></html>", charset: "x-nonsense")).text
    assert_includes unknown, "ok"
  end

  # A LEGACY MULTIBYTE CHARSET decodes with replacement, as text does,
  # whether the header or a `<meta>` declares it: a Windows-31J character on
  # a page declared Shift_JIS, a stray lead byte, and the render cut through
  # a two-byte character each render.
  def test_a_legacy_multibyte_page_renders_with_replacement_and_never_raises_an_encoding_error
    sjis = ->(text) { text.encode(Encoding::Shift_JIS).b }
    body = "<html><head><title>T</title></head><body><p>".b + sjis.("日本語") + "\x87\x40 \x81".b + "</p></body></html>".b
    rendering = Rho::WebTools::Render.call(page(body, charset: "Shift_JIS"))
    assert_equal :markdown, rendering.kind
    assert_predicate rendering.text, :valid_encoding?
    assert_includes rendering.text, "日本語\uFFFD"

    # "<html><body><p>" is 15 bytes, so every character from there starts at
    # an odd offset and the last byte the cut keeps is a lead byte.
    long = "<html><body><p>".b + (sjis.("日") * ((Rho::WebTools::Render::RENDER_INPUT_BYTES / 2) + 64)) + "</p></body></html>".b
    assert_equal 0x93, long.getbyte(Rho::WebTools::Render::RENDER_INPUT_BYTES - 1)
    cut = Rho::WebTools::Render.call(page(long, charset: "Shift_JIS"))
    assert_equal Rho::WebTools::Render::RENDER_INPUT_BYTES, cut.cut
    assert_predicate cut.text, :valid_encoding?
    assert cut.text.start_with?("日日日"), cut.text[0, 20]

    meta = "<html><head><meta charset=\"Shift_JIS\"></head><body><p>".b + sjis.("日本語") + "\x87\x40".b + "</p></body></html>".b
    declared = Rho::WebTools::Render.call(page(meta))
    assert_predicate declared.text, :valid_encoding?
    assert_includes declared.text, "日本語\uFFFD", "a meta-declared charset renders with replacement too"
  end

  # NO DECLARATION ANYWHERE — no header charset, no `<meta>`, no BOM — is
  # almost always UTF-8 today, and WHATWG's legacy fallback is windows-1252
  # when the bytes are not UTF-8. nokogiri's own default was ISO-8859-1,
  # which turned every UTF-8 page without a declaration into mojibake and
  # dropped windows-1252's € as a C1 control.
  def test_an_undeclared_page_is_read_as_utf8_else_windows_1252
    utf8 = Rho::WebTools::Render.call(page("<html><body><p>Köln 日本 “q”</p></body></html>")).text
    assert_includes utf8, "Köln 日本 “q”"

    legacy = Rho::WebTools::Render.call(page("<html><body><p>price \x80 5, caf\xE9</p></body></html>".b)).text
    assert_includes legacy, "price € 5, café"

    http_equiv = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1252\"></head>" \
                 "<body><p>\x93q\x94</p></body></html>"
    assert_includes Rho::WebTools::Render.call(page(http_equiv.b)).text, "“q”", "the http-equiv spelling declares too"

    # A UTF-8 page past the render bound, cut through a three-byte
    # character, is still UTF-8: only the cut tail is incomplete.
    long = "<html><body><p>".b + ("日" * ((Rho::WebTools::Render::RENDER_INPUT_BYTES / 3) + 64)).b + "</p></body></html>".b
    refute_equal 0, (Rho::WebTools::Render::RENDER_INPUT_BYTES - 15) % 3, "the fixture's cut lands inside a character"
    cut = Rho::WebTools::Render.call(page(long))
    assert_equal Rho::WebTools::Render::RENDER_INPUT_BYTES, cut.cut
    assert cut.text.start_with?("日日日"), cut.text[0, 20]
  end

  def test_text_is_verbatim_transcoded_by_its_charset_and_the_controls_stripped
    verbatim = Rho::WebTools::Render.call(page("line one\nline two\n", media_type: "text/plain"))
    assert_equal :verbatim, verbatim.kind
    assert_equal "line one\nline two\n", verbatim.text
    assert_nil verbatim.title
    latin = Rho::WebTools::Render.call(page("caf\xE9".b, media_type: "text/plain", charset: "iso-8859-1"))
    assert_equal "café", latin.text
    # The ESC byte goes (a terminal reads nothing); its printable
    # parameters stay as the text they are.
    dirty = "a​b\e[31mc‮d\tkeep\r\nlines\x00end"
    assert_equal "ab[31mcd\tkeep\r\nlinesend", Rho::WebTools::Render.clean(dirty)
  end

  def test_the_content_type_table_row_by_row
    render = Rho::WebTools::Render
    %w[text/html application/xhtml+xml].each { |type| assert render.html?(type), type }
    %w[text/markdown text/plain text/csv application/json application/xml application/javascript
       application/ld+json image/svg+xml].each do |type|
      refute render.html?(type), type
      assert render.text?(type), type
    end
    %w[image/png application/pdf application/zip application/octet-stream].each do |type|
      refute render.html?(type), type
      refute render.text?(type), type
      assert_equal :bytes, render.call(page("x", media_type: type)).kind
    end
    assert_equal :verbatim, render.call(page("{}", media_type: "application/json")).kind
    assert_equal :markdown, render.call(page("<p>x</p>", media_type: "application/xhtml+xml")).kind
  end

  def test_a_page_without_a_title_has_none_and_an_empty_page_renders_empty
    assert_nil Rho::WebTools::Render.call(page("<html><body><p>no title</p></body></html>")).title
    assert_equal "", Rho::WebTools::Render.call(page("")).text
  end

  # THE RENDER INPUT BOUND. The 5 MiB worst case did not render under 5 s (unfinished
  # after 330 s in a local probe), so the input is cut at RENDER_INPUT_BYTES before the
  # parse and the cut is the rendering's own fact. TWO PROPERTIES, neither the wall
  # clock's: the 5 MiB page's rendering IS the 1 MiB prefix's rendering byte for byte
  # (nothing past the cut is parsed — the mechanism the budget rests on), and the cut
  # render costs under the 15 s budget in this process's CPU time — the work, which three
  # trees' suites beside this one cannot inflate the way they inflate a wall-clock read
  # (the flake under load). The render budget takes 15 s out of the 45 s cancel deadline
  # (30 s fetch + 15 s parse and render — wall arithmetic, the daemon's clock); CPU time
  # is THE ACCEPTED READING of that budget for THIS assertion: the property is the
  # render's cost, and the one clock a loaded machine cannot inflate is the one that
  # measures it.
  def test_the_five_mib_page_is_cut_at_the_render_input_bound_and_rendered_under_the_budget
    cap = Rho::WebTools::Client::WIRE_CAP
    body = +""
    n = 0
    while body.bytesize < cap
      n += 1
      body << "<h2>Section #{n}</h2><p>Paragraph #{n} with a <a href=\"/p/#{n}\">link</a>, <em>emphasis</em> and " \
              "<strong>bold</strong> text that runs on like prose on a documentation page.</p>" \
              "<ul><li>item a</li><li>item b</li></ul><pre><code>code #{n}</code></pre>\n"
    end
    html = "<html><head><title>Big</title></head><body>#{body}</body></html>".byteslice(0, cap)
    assert_equal cap, html.bytesize
    cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    rendering = Rho::WebTools::Render.call(page(html))
    cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu
    assert_equal Rho::WebTools::Render::RENDER_INPUT_BYTES, rendering.cut
    assert_equal 1_048_576, Rho::WebTools::Render::RENDER_INPUT_BYTES
    assert_includes rendering.text, "## Section 1\n"
    assert_operator rendering.text.bytesize, :<, Rho::WebTools::Render::RENDER_INPUT_BYTES
    assert_operator cpu, :<, 15, "the cut render cost #{cpu.round(2)}s of CPU, over the 15 s budget"
    prefix = Rho::WebTools::Render.call(page(html.byteslice(0, Rho::WebTools::Render::RENDER_INPUT_BYTES)))
    assert_nil prefix.cut
    assert_equal prefix.text, rendering.text, "the cut page renders as its prefix: nothing past the cut is parsed"
    assert_equal prefix.title, rendering.title
  end
end
