require "puma"
require "puma/server"
require "puma/log_writer"
require "rack"
require_relative "red_square_png"

module E2E
  # THE PAGES `web_fetch` READS: one Rack app served by TWO `Puma::Server`s on loopback ports of the
  # OS's choosing, IN the journey's process (rho-mcp's `serve` shape; puma and rack are in e2e's
  # lock). The second listener is "another site": `127.0.0.1:A` and `127.0.0.1:B` differ in port, so
  # the tool's `same_site?` halts between them and `/away` is a cross-site redirect the model is
  # told about. Every request is kept as its URL (`requests`), so a refusal that must open NO socket
  # is pinned by the count standing still, and a redirect that must not be followed by the other
  # site's silence.
  class WebFixture
    # 140 KB of paragraphs — over the runner's 50 KiB byte cap, so the
    # rendering is cut and spilled.
    LONG_PARAGRAPHS = 1800
    BIG_CONTENT_LENGTH = 6_291_456

    attr_reader :site, :other, :app

    def initialize
      @app = App.new
      @servers = []
      @site = nil
      @other = nil
    end

    def start
      @site = serve
      @other = serve
      @app.other = @other
      self
    end

    def stop
      @servers.each { |server| server.halt(true) rescue nil }
      @servers = []
    end

    def requests = @app.requests

    # Puma on a loopback port of the OS's choosing, quiet; the base URL.
    def serve
      server = Puma::Server.new(@app, nil, min_threads: 0, max_threads: 8, log_writer: Puma::LogWriter.null)
      server.add_tcp_listener("127.0.0.1", 0)
      server.run
      @servers << server
      "http://127.0.0.1:#{server.connected_ports.fetch(0)}"
    end

    # THE PAGE: a title, an `h1`, two paragraphs, a link (absolute, so the
    # rendering names the site), a `script` and a `style` block, an `img`,
    # one zero-width space in the second paragraph.
    def self.page(base)
      <<~HTML
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Fixture Page</title>
        <style>body { color: red } /* STRIPPED_STYLE */</style>
        <script>alert("STRIPPED_SCRIPT")</script></head>
        <body>
        <h1>Fixture Heading</h1>
        <p>The first paragraph, with a <a href="#{base}/other">link text</a> inside it.</p>
        <p>The second​ paragraph carries a zero-width space.</p>
        <img src="#{base}/pixel.png" alt="a red square">
        </body></html>
      HTML
    end

    LONG = (1..LONG_PARAGRAPHS).map { |n| "<p>Paragraph #{n} of the long page, long enough to pass the byte cap.</p>" }
      .join("\n").then { |body| "<html><head><title>Long</title></head><body>#{body}</body></html>" }.freeze
    NOTES = "line one\nline two\n".freeze
    DATA = "{\"answer\": 42, \"list\": [1, 2, 3]}".freeze
    GONE = "Nothing here to choose from.\nsecond line".freeze
    MISSING = "no such page\nsecond line".freeze

    class App
      attr_accessor :other
      attr_reader :requests

      def initialize
        @requests = []
        @other = nil
      end

      def call(env)
        base = "http://#{env["HTTP_HOST"]}"
        @requests << "#{base}#{env["PATH_INFO"]}"
        case env["PATH_INFO"]
        when "/page.html" then html(WebFixture.page(base))
        when "/long.html" then html(LONG)
        when "/same" then [302, { "content-type" => "text/html", "location" => "#{base}/page.html" }, ["<html><body>Redirecting…</body></html>"]]
        when "/away" then [302, { "content-type" => "text/plain", "location" => "#{@other}/page.html" }, ["moved"]]
        when "/loop" then [302, { "content-type" => "text/plain", "location" => "#{base}/loop" }, ["moved"]]
        when "/gone" then [300, { "content-type" => "text/plain" }, [GONE]]
        when "/notes.txt" then [200, { "content-type" => "text/plain; charset=utf-8" }, [NOTES]]
        when "/data.json" then [200, { "content-type" => "application/json" }, [DATA]]
        when "/pixel.png" then [200, { "content-type" => "image/png" }, [RedSquarePng.bytes]]
        when "/missing" then [404, { "content-type" => "text/plain" }, [MISSING]]
        when "/big" then [200, { "content-type" => "text/plain", "content-length" => BIG_CONTENT_LENGTH.to_s }, endless]
        else [404, { "content-type" => "text/plain" }, ["not a fixture page"]]
        end
      end

      private

        def html(body) = [200, { "content-type" => "text/html; charset=utf-8" }, [body]]

        # A body that keeps writing until the peer closes (bounded, so a
        # server nobody reads still ends).
        def endless
          Enumerator.new { |y| 128.times { y << ("x" * 65_536) } }
        end
    end
  end
end
