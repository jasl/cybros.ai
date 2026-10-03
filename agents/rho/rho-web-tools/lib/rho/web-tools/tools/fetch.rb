require "net/http"
require "securerandom"

module Rho
  module WebTools
    module Tools
      # `web_fetch {url}`: the one tool. A GET of a
      # public http(s) URL through the client, rendered, answered under the
      # runner's own truncation caps with bash's own spill footer — the
      # FULL rendering written to the runner's artifacts directory ONLY
      # when cut, so the model pages the rest with `read {path, offset}`
      # as it pages a bash spill; an image or other binary saved ALWAYS,
      # readable through the same `read` (an image reaches a vision model
      # through the plane's own two verbs). Announced `read_only` on the
      # OPEN world — network access in the kernel's
      # closed vocabulary — so it runs under `bypass`, parks under `ask`
      # and is refused under `rules` until a rule allows it; it gets NO
      # ask row of its own, because `ask` beats `allow` in the kernel's
      # evaluation and an ask row would defeat every per-host allow.
      # The model reads, in order: ONE status line, a blank line, the
      # rendered text under the caps, and — when cut — the footer.
      class Fetch
        NAME = "web_fetch".freeze # canonical rho.web_tools.fetch (tool.rb's example)
        EFFECT_PROFILE = Ractor.make_shareable({
          "kind" => "read_only", "destructive" => false, "world" => "open",
          "idempotency" => "intrinsic", "reconciliation" => "none",
        })
        # Cancelled by the runner at 45 s = 30 s for the fetch (the
        # client's deadline) + 15 s for parse and render: the pool cancels
        # every handler at `deadline − headroom`, `headroom = [15,
        # remaining/4].min`; a 45 s park would have left the render 3.75 s.
        TIMEOUT_MS = 60_000
        INTERNAL_CLAMP = true
        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => { "url" => { "type" => "string", "description" => "The URL to fetch content from" } },
          "required" => ["url"],
        })
        DESCRIPTION =
          "Fetches content from a specified URL. The URL must be a fully-formed valid URL (http:// or https://). " \
          "HTML is converted to markdown; other text is returned as-is; an image or other binary is saved to a " \
          "file you can read. Output is truncated to #{Rho::Runner::Truncation::DEFAULT_MAX_LINES} lines or " \
          "#{Rho::Runner::Truncation.format_size(Rho::Runner::Truncation::DEFAULT_MAX_BYTES)} (whichever is hit first); if truncated, the full " \
          "page is saved to a file named in the result — continue with read on it. This tool is read-only and does " \
          "not modify any files. A redirect to another site is reported, not followed — call again with the new URL. " \
          "Use this tool when you need to retrieve and analyze web content. " \
          "Example: {\"url\": \"https://docs.ruby-lang.org/en/master/String.html\"}".freeze
        PROMPT_SNIPPET = "Fetch a web page by URL".freeze
        PROMPT_GUIDELINES = Ractor.make_shareable([
          "Use web_fetch to read a page or a raw file from the web instead of curl or wget in bash; " \
            "it is a read and returns markdown.",
        ])

        # THE STATUS LINE IS OUTSIDE THE CAP and itself shortened, by the
        # client's one rule (`WebTools.shorten`): the URL at `URL_MAX_BYTES`, the
        # title at rho-browser's `SnapshotText::TITLE_BYTES`, declared here
        # by value because rho-web-tools cannot depend on rho-browser.
        TITLE_MAX_BYTES = 256
        # read's own `IMAGE_EXTENSIONS` without the dot: for these the
        # media SUBTYPE is the extension `read` recognises.
        IMAGE_SUBTYPES = %w[png jpeg gif webp bmp].freeze
        PATH_EXTENSION = /\A\.[a-z0-9]{1,8}\z/
        # A saved page's name: `web-<digest>` and its extension.
        CAPTURE_PREFIX = "web".freeze

        class << self
          # `<url> — <status> <media type>; <fetched> fetched[, rendered the
          # first N of M][, <size> markdown][ (n redirects)][; title: …]`.
          def status_line(page, rendering)
            line = "#{WebTools.shorten(page.final_url, URL_MAX_BYTES)} — #{page.status} #{page.media_type}; " \
                   "#{size(page.bytes)} fetched"
            line += ", rendered the first #{size(rendering.cut)} of #{size(page.bytes)}" if rendering.cut
            line += ", #{size(rendering.text.bytesize)} markdown" if rendering.kind == :markdown
            line += " (#{page.redirects} redirect#{"s" unless page.redirects == 1})" if page.redirects.positive?
            line += "; title: #{WebTools.shorten(rendering.title, TITLE_MAX_BYTES)}" if rendering.title
            line
          end

          # A status the model reads as DATA — a 4xx/5xx, a 3xx that named
          # no `Location` — with the body's first bytes under it.
          def answered(page)
            head = "#{page.url} answered #{page.status}#{phrase(page.status)}"
            excerpt = Render.clean(Render.decode(page.body, page.charset)).strip
            excerpt.empty? ? head : "#{head}\n\n#{excerpt}"
          end

          # Ruby's own table (`Net::HTTPResponse::CODE_TO_OBJ`), the class
          # name read as words: `Net::HTTPNotFound` → "Not Found".
          def phrase(status)
            klass = Net::HTTPResponse::CODE_TO_OBJ[status.to_s]
            return "" if klass.nil?

            " #{klass.name.delete_prefix("Net::HTTP").gsub(/(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])/, " ")}"
          end

          def size(bytes) = Rho::Runner::Truncation.format_size(bytes)
        end

        def initialize(env:)
          @env = env
        end

        def call(args)
          Rho::Runner::ExecutionContext.current&.raise_if_cancelled!
          url = args.fetch("url").to_s
          started = now
          uri = UrlRule.parse(url)
          page = Client.new(allow_private_network: Rho::WebTools.allow_private_network?).get(uri)
          answer(page, started)
        rescue Refused => error
          log&.info("web.refused", host: host_of(url), reason: error.reason.to_s)
          Rho::Runner::Result.error(error.message, structure(url: url))
        rescue Redirected => error
          log&.info("web.refused", host: host_of(url), reason: "redirect")
          Rho::Runner::Result.error(error.message, structure(url: url, final_url: error.location, status: error.status))
        rescue TooLarge => error
          log&.info("web.refused", host: host_of(url), reason: "too_large")
          Rho::Runner::Result.error(error.message, structure(url: url, bytes: error.bytes))
        rescue Unreachable, Render::Unrenderable => error
          log&.warn("web.failed", host: host_of(url), error_class: error.class.name, ms: elapsed(started))
          Rho::Runner::Result.error(error.message, structure(url: url))
        end

        private

          def log = Rho::WebTools.log

          def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          def elapsed(started) = ((now - started) * 1000).round

          def host_of(url)
            URI.parse(url).host
          rescue URI::InvalidURIError
            nil
          end

          def answer(page, started)
            return answered(page, started) if page.error? || page.redirect?

            rendering = Render.call(page)
            result =
              if rendering.kind == :bytes
                bytes(page, rendering)
              else
                text(page, rendering)
              end
            log&.info("web.fetch", host: host_of(page.final_url), status: page.status, content_type: page.media_type,
              bytes: page.bytes, rendered_bytes: rendering.text&.bytesize || 0, redirects: page.redirects,
              ms: elapsed(started))
            result
          end

          def answered(page, started)
            log&.info("web.fetch", host: host_of(page.final_url), status: page.status, content_type: page.media_type,
              bytes: page.bytes, rendered_bytes: 0, redirects: page.redirects, ms: elapsed(started))
            Rho::Runner::Result.error(self.class.answered(page), structure(page: page))
          end

          # THE BOUND AND THE SPILL: `truncate_head` with the runner's
          # defaults (bytes the wall); ONLY when cut, the whole rendering
          # goes to `artifacts/web-<digest>.md` and the footer is bash's,
          # verbatim, with `format_size`'s spelling; the path rides
          # `files:` so a client fetches the page as a capture.
          def text(page, rendering)
            truncation = Rho::Runner::Truncation.truncate_head(rendering.text)
            spill = truncation.truncated ? write(".md", rendering.text) : nil
            body = truncation.first_line_exceeds_limit ? "" : truncation.content
            content = "#{self.class.status_line(page, rendering)}\n\n#{body}#{footer(truncation, spill)}"
            Rho::Runner::Result.ok(content, structure(page: page, truncation: truncation), files: spill ? [spill] : [])
          end

          def footer(truncation, spill)
            return "" unless truncation.truncated

            limit = self.class.size(truncation.max_bytes)
            if truncation.first_line_exceeds_limit
              "[Line 1 is #{self.class.size(truncation.total_bytes)}, exceeds #{limit} limit. Full output: #{spill}]"
            elsif truncation.truncated_by == :lines
              "\n\n[Showing lines 1-#{truncation.output_lines} of #{truncation.total_lines}. Full output: #{spill}]"
            else
              "\n\n[Showing lines 1-#{truncation.output_lines} of #{truncation.total_lines} (#{limit} limit). " \
                "Full output: #{spill}]"
            end
          end

          # Bytes are written ALWAYS, named by the URL path's own extension
          # when it has one, else by the image subtype `read` knows, else
          # `.bin`; `read` on an image answers "image attached".
          def bytes(page, _rendering)
            path = write(extension(page), page.body)
            Rho::Runner::Result.ok("#{WebTools.shorten(page.final_url, URL_MAX_BYTES)} — #{page.status} #{page.media_type}; " \
                                   "#{self.class.size(page.bytes)} saved to #{path}", structure(page: page), files: [path])
          end

          def extension(page)
            own = File.extname(URI.parse(page.final_url).path.to_s).downcase
            return own if own.match?(PATH_EXTENSION)

            subtype = page.media_type.split("/").last.to_s
            IMAGE_SUBTYPES.include?(subtype) ? ".#{subtype}" : ".bin"
          rescue URI::InvalidURIError
            ".bin"
          end

          # Named by content: the same page is the same path, so a re-fetch of
          # an unchanged page reads as the same result.
          def write(extension, bytes)
            path = File.join(@env.ensure_artifacts_dir!, "#{CAPTURE_PREFIX}-#{SecureRandom.hex(8)}#{extension}")
            File.binwrite(path, bytes)
            @env.keep_capture(path, CAPTURE_PREFIX)
          end

          # The UI's channel, never the model's: the six keys always, the
          # truncation in bash's details shape when the text was cut.
          def structure(page: nil, url: nil, final_url: nil, status: nil, bytes: 0, truncation: nil)
            details = truncation&.truncated ? truncation.to_h.transform_keys(&:to_s) : nil
            {
              "url" => page ? page.url : url,
              "final_url" => page ? page.final_url : final_url,
              "status" => page ? page.status : status,
              "content_type" => page&.media_type,
              "bytes" => page ? page.bytes : bytes,
              "truncation" => details,
            }
          end
      end
    end
  end
end
