require "puma"
require "puma/server"
require "puma/log_writer"
require "rack"
require "zlib"

module WebToolsTest
  # THE PAGES THE SUITE FETCHES, as a Rack app ((d)):
  # every request's headers are kept in `seen` (the UA and Accept pins),
  # `other` is the second site's base URL for `/away`, and `slow_seconds`
  # how long `/slow` sleeps.
  class FixtureApp
    attr_reader :seen
    attr_accessor :other, :slow_seconds

    PAGE = <<~HTML.freeze
      <!doctype html>
      <html><head><meta charset="utf-8"><title>Fixture Page</title>
      <style>body { color: red }</style>
      <script>alert("STRIPPED_SCRIPT")</script></head>
      <body>
      <h1>Fixture Heading</h1>
      <p>The first paragraph, with a <a href="/other">link text</a> inside it.</p>
      <p>The second​ paragraph carries a zero-width space.</p>
      <img src="/pixel.png" alt="a red square">
      <noscript>STRIPPED_NOSCRIPT</noscript>
      <svg><text>STRIPPED_SVG</text></svg>
      </body></html>
    HTML

    # A red square on white, as bytes — the harness's own PNG, lifted.
    PNG = begin
      side = 24
      rows = (0...side).map do |y|
        row = "\x00".b
        (0...side).each { |x| row << ((6..17).cover?(x) && (6..17).cover?(y) ? "\xff\x00\x00".b : "\xff\xff\xff".b) }
        row
      end.join
      chunk = lambda do |type, data|
        [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
      end
      ("\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [side, side, 8, 2, 0, 0, 0].pack("NNC5")) +
        chunk.call("IDAT", Zlib::Deflate.deflate(rows)) + chunk.call("IEND", "".b)).freeze
    end

    LONG = (1..4000).map { |n| "<p>Paragraph #{n} of the long page, long enough to pass the byte cap.</p>" }
      .join("\n").then { |body| "<html><head><title>Long</title></head><body>#{body}</body></html>" }.freeze

    # Three `Location`s no URI parser takes, spelled as a careless server
    # sends them: a space, a host that is no address, raw UTF-8 bytes.
    MALFORMED = ["http://exa mple.com/x", "http://[not-an-ip]/", "http://x/Köln"].freeze

    # Four `Alt-Svc` values httpx 1.8.4 cannot parse: its parser never
    # advances past a token that is not name=value (the first three), and
    # raises URI::InvalidURIError on an authority no URI parser takes.
    ALT_SVC = ["garbage", 'h2=":443", junk', 'h2=":443"; persist', 'h2="exa mple:443"'].freeze

    # A `Location` far past any budget, as a hostile server sends it: valid
    # on another site, and malformed with spaces and raw non-ASCII bytes.
    HUGE_PATH_BYTES = 100_000
    # A long redirect target a real server still accepts: a presigned URL
    # with a session token is thousands of bytes, under any common
    # request-line limit.
    LONG_PATH_BYTES = 3_000
    HUGE_MALFORMED = "http://x/#{(["Köln"] * (HUGE_PATH_BYTES / 6)).join(" ")}".freeze

    def initialize
      @seen = []
      @other = nil
      @slow_seconds = 5
    end

    def call(env)
      @seen << env.select { |key, _| key.start_with?("HTTP_") }
      base = "http://#{env["HTTP_HOST"]}"
      case env["PATH_INFO"]
      when "/page.html" then html(PAGE)
      when "/long.html" then html(LONG)
      when "/same" then [302, { "content-type" => "text/html", "location" => "#{base}/page.html" }, ["<html><body>Redirecting…</body></html>"]]
      when "/relative" then [302, { "content-type" => "text/plain", "location" => "/page.html" }, ["moved"]]
      when "/away" then [302, { "content-type" => "text/plain", "location" => "#{@other}/page.html" }, ["moved"]]
      when "/hop" then [302, { "content-type" => "text/plain", "location" => "#{base}/hop2" }, ["moved"]]
      when "/hop2" then [302, { "content-type" => "text/plain", "location" => "#{@other}/page.html" }, ["moved"]]
      when "/loop" then [302, { "content-type" => "text/plain", "location" => "#{base}/loop" }, ["moved"]]
      when %r{\A/malformed/(\d)\z} then moved(MALFORMED.fetch(Integer(Regexp.last_match(1))))
      when %r{\A/spent/(\d)\z} then spent(base, Integer(Regexp.last_match(1)))
      when %r{\A/alt-svc/(\d)\z}
        [200, { "content-type" => "text/plain", "alt-svc" => ALT_SVC.fetch(Integer(Regexp.last_match(1))) }, ["alt-svc page"]]
      when %r{\A/alt-svc-hop/(\d)\z}
        [302, { "content-type" => "text/plain", "location" => "#{base}/notes.txt",
                "alt-svc" => ALT_SVC.fetch(Integer(Regexp.last_match(1))) }, ["moved"]]
      when "/huge/cross" then moved("#{@other}/#{"a" * HUGE_PATH_BYTES}")
      when "/long/cross" then moved("#{@other}/#{"a" * LONG_PATH_BYTES}")
      when "/huge/malformed" then moved(HUGE_MALFORMED)
      when "/long-image" then moved("#{base}/pixel.png?#{"q" * 2000}")
      when "/retry-after" then [302, { "content-type" => "text/plain", "location" => "/notes.txt", "retry-after" => "soon" }, ["moved"]]
      when "/gone" then [300, { "content-type" => "text/plain" }, ["Nothing here to choose from.\nsecond line"]]
      when "/notes.txt" then [200, { "content-type" => "text/plain; charset=utf-8" }, ["line one\nline two\n"]]
      when "/latin.txt" then [200, { "content-type" => "text/plain; charset=iso-8859-1" }, ["caf\xE9".b]]
      when "/data.json" then [200, { "content-type" => "application/json" }, ["{\"answer\": 42}"]]
      when "/pixel.png" then [200, { "content-type" => "image/png" }, [PNG]]
      when "/picture" then [200, { "content-type" => "image/jpeg" }, [PNG]]
      when "/blob" then [200, { "content-type" => "application/octet-stream" }, ["\x00\x01\x02".b]]
      when "/missing" then [404, { "content-type" => "text/plain" }, ["no such page\nsecond line"]]
      when "/big" then [200, { "content-type" => "text/plain", "content-length" => "6291456" }, endless]
      when "/stream" then [200, { "content-type" => "text/plain" }, chunks(6 * 1024 * 1024)]
      when "/slow" then sleep(@slow_seconds); [200, { "content-type" => "text/plain" }, ["late"]]
      when "/same-slow" then [302, { "content-type" => "text/plain", "location" => "#{base}/slow" }, ["moved"]]
      when "/oneline.json" then [200, { "content-type" => "application/json" }, ["[" + (["1"] * 30_000).join(",") + "]"]]
      when "/meta.html" then [200, { "content-type" => "text/html" }, ["<html><head><meta charset=\"windows-1252\"><title>Meta</title></head><body><p>caf\xE9 \x93quoted\x94</p></body></html>".b]]
      when "/header.html" then [200, { "content-type" => "text/html; charset=iso-8859-1" }, ["<html><head><title>Header</title></head><body><p>na\xEFve</p></body></html>".b]]
      when "/fenced.html" then html("<html><body><p>before</p><pre><code>def a\n  1\nend</code></pre><p>after</p></body></html>")
      else [404, { "content-type" => "text/plain" }, ["not a fixture page"]]
      end
    end

    private

      def html(body) = [200, { "content-type" => "text/html; charset=utf-8" }, [body]]

      def moved(location) = [302, { "content-type" => "text/plain", "location" => location }, ["moved"]]

      # `/spent/N` is N same-site hops ahead of a malformed `Location`, so
      # `/spent/3` names it on the answer that spends the redirect bound.
      def spent(base, left) = moved(left.zero? ? MALFORMED.first : "#{base}/spent/#{left - 1}")

      # A body that keeps writing until the peer closes (bounded, so a
      # server nobody reads still ends).
      def endless
        Enumerator.new { |y| 128.times { y << ("x" * 65_536) } }
      end

      def chunks(total)
        Enumerator.new { |y| (total / 65_536).times { y << ("y" * 65_536) } }
      end
  end
end
