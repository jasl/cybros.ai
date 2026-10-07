require "httpx"
# The rescue below can run before the first session loads this plugin.
require "httpx/plugins/follow_redirects"
# THE ONE THIRD-PARTY WARNING, SILENCED WHERE IT IS MADE: httpx's SSRF
# filter computes its IPv6 blacklist at plugin load through
# `IPAddr#ipv4_compat`, which `warn`s "obsolete" under `$VERBOSE`
# (ipaddr.rb, `if $VERBOSE`, no category — a `Warning` category filter
# cannot name it) — sixteen lines on stderr at a process's FIRST session
# under `ruby -w`, inside whichever test captured stderr first. The plugin
# is required ONCE here, with `$VERBOSE` at its `-W1` level for that
# require alone; `HTTPX.plugin(:ssrf_filter)` then finds it registered and
# requires nothing. Not a filter on stderr (a daemon under `-w` would still
# print them) and not a global switch (every other warning stays).
begin
  verbose = $VERBOSE
  $VERBOSE = false
  require "httpx/plugins/ssrf_filter"
ensure
  $VERBOSE = verbose
end
require "ipaddr"
require "uri"
require "cybros_agent/http_deadline"

module Rho
  module WebTools
    # The gem's own root under the runner's, so a refusal raised here is
    # the runner's kind of error wherever it is read.
    class Error < Rho::Runner::Error; end
    # BEFORE A SOCKET, OR BY THE ADDRESS FILTER: the URL as written is not
    # one this tool fetches. One sentence, the model reads it and corrects
    # the call (`Result.error`, never a failed task). `reason` is the log
    # fact — `:url` from the rule, `:private_address` from the filter.
    class Refused < Error
      attr_reader :reason

      def initialize(message, reason: :url)
        super(message)
        @reason = reason
      end
    end
    # The wire did not answer: the deadline, a refused connect, a name that
    # does not resolve, a failed TLS handshake — or it answered with a header
    # httpx cannot parse.
    class Unreachable < Error; end
    # Over the wire cap — the Content-Length said so, or the counter did.
    # `bytes` is what the CLIENT counted before it stopped: 0 when the
    # header refused it before the body was read.
    class TooLarge < Error
      attr_reader :bytes

      def initialize(message, bytes:)
        super(message)
        @bytes = bytes
      end
    end
    # A redirect this client will not follow — cross-site, https → http,
    # the bound spent, a `Location` no URI parser takes, or a same-site hop
    # whose `Retry-After` httpx cannot parse — reported with the status it
    # answered and the `Location` it named. A malformed `Location`, or one
    # longer than `Client::URL_ACTIONABLE_BYTES`, leaves `location` nil,
    # because that field names a URL a caller could fetch whole; the
    # sentence shows the header, shortened.
    class Redirected < Error
      attr_reader :status, :location

      def initialize(message, status:, location:)
        super(message)
        @status = status
        @location = location
      end
    end

    # THE ONE SHORTENING RULE for a URL the model reads outside the output
    # cap: rho-browser's `SnapshotText.shorten` shape (one line, an
    # ellipsis, the count), declared here by value because rho-web-tools cannot
    # depend on rho-browser. No header size limit and no URL length rule
    # stand in front of it, so the bound is what keeps a 60 KB URL out of
    # the budget, whichever side wrote it. A URL shown only to be READ — the
    # status line's final URL, a malformed `Location` — is shortened at 512
    # B. A `Location` the model is told to FOLLOW is shortened at
    # `Client::URL_ACTIONABLE_BYTES` instead, so a real long one stays whole.
    URL_MAX_BYTES = 512

    def self.shorten(text, bytes)
      return text if text.bytesize <= bytes

      tail = format(" …(%d more bytes)", text.bytesize)
      kept = text.byteslice(0, [bytes - tail.bytesize, 0].max).scrub("")
      kept + format(" …(%d more bytes)", text.bytesize - kept.bytesize)
    end

    # WHAT IS REFUSED BEFORE A SOCKET OPENS, in
    # this order, each with ONE sentence. Nothing is normalized: the
    # kernel's rule grammar judges `tool_input.url` AS WRITTEN
    # (`runs.md` "match" is byte-literal), so a URL this tool
    # rewrote would run under a rule that saw different text — the
    # doctrine's "reject invalid input rather than sanitizing it into a
    # semantically different value". The
    # canonical-host rule is the spelling-proof half of the private-
    # network refusal: an operator's deny row `*.corp.internal*` must not
    # be walked around with `CORP.INTERNAL`, `corp.internal.`,
    # `c%6frp.internal` or `0x0a000005` (all of which `getaddrinfo` takes).
    module UrlRule
      SCHEMES = %w[http https].freeze
      NOT_A_URL = "url is not a valid URL; percent-encode non-ASCII characters in the path and query, " \
                  "and write the host in lowercase ASCII".freeze
      SCHEME = "url must be http:// or https://".freeze
      CREDENTIALS = "url carries credentials before the host; web_fetch sends none — remove them and call again".freeze
      # A host whose last label reads as a number is an IPv4 literal to
      # `getaddrinfo` (decimal, octal, hex, and fewer than four parts);
      # here it must be what `IPAddr` accepts — four dotted decimals.
      NUMERIC_LABEL = /\A(0x[0-9a-f]+|[0-9]+)\z/i

      module_function

      # The parsed `URI::HTTP` a rule can judge, or a `Refused` with the
      # sentence the model reads.
      def parse(url)
        text = url.to_s
        raise Refused, NOT_A_URL unless text.ascii_only?

        uri = begin
          URI.parse(text)
        rescue URI::InvalidURIError
          raise Refused, NOT_A_URL
        end
        raise Refused, SCHEME unless SCHEMES.include?(uri.scheme)
        raise Refused, CREDENTIALS if uri.userinfo

        canonical_host!(uri.host.to_s)
        uri
      end

      # Same scheme, same port, no userinfo on the target, hosts equal
      # after stripping one leading `www.` — claude-code's rule
      # (`utils.ts:212-243`), judged against the ORIGINAL URL on every hop.
      def same_site?(original, location)
        return false if location.userinfo || location.host.to_s.empty?

        original.scheme == location.scheme && original.port == location.port &&
          bare(original.host) == bare(location.host)
      end

      def bare(host) = host.to_s.delete_prefix("www.")

      def not_canonical(host)
        "url host #{host.inspect} is not canonical; write it in lowercase ASCII without a trailing dot, " \
          "an IPv4 address as four dotted decimals"
      end

      # An IPv6 literal in brackets passes: it is judged by ADDRESS.
      def canonical_host!(host)
        return if host.start_with?("[") && host.end_with?("]")
        raise Refused, not_canonical(host) if host.empty? || host != host.downcase || host.end_with?(".") ||
                                             host.include?("%")
        return unless host.split(".").last.to_s.match?(NUMERIC_LABEL)

        quad = IPAddr.new(host, Socket::AF_INET)
        raise Refused, not_canonical(host) unless quad.ipv4? && host == quad.to_s
      rescue IPAddr::Error
        raise Refused, not_canonical(host)
      end
    end

    # ONE ANSWER FROM THE WIRE: the final response of a followed chain, a
    # halted-without-Location 3xx or a 4xx/5xx (both DATA the model reads),
    # with its body as BYTES — the render decides what they mean.
    # `bytes` is the client's own count of the decoded body (the wall
    # against a gzip bomb); `body` is capped at `ERROR_BODY_BYTES` for a
    # status of 400 and up. `media_type` is the `Content-Type` without its
    # parameters, downcased; `charset` its parameter when present.
    Page = Data.define(:url, :final_url, :status, :media_type, :charset, :body, :bytes, :redirects) do
      def redirect? = Client::REDIRECT_STATUS.cover?(status)
      def error? = status >= 400
    end

    # The cancel is observed on the blocked thread at the selector's tick (wrapped as the
    # SDK's `HttpDeadline` wraps its `initial_call`, a one-shot `POLL_SECONDS` timer
    # bounding the select) — `Session#close` from another thread reaches nothing in flight.
    module CancelWatch
      POLL_SECONDS = 0.2
      # The error the expired request carries; the client maps it to the
      # context's own `Cancelled` and never lets it out.
      class Interrupted < HTTPX::Error; end

      module InstanceMethods
        private

        def receive_requests(requests, selector)
          timers = []
          pending = false
          watch = Module.new do
            define_method(:next_tick) do
              open = requests.reject { |request| request.response&.finished? }
              if !open.empty? && Rho::Runner::ExecutionContext.current&.cancelled?
                each.to_a.each { |selectable| selectable.force_close(true) }
                open.each do |request|
                  request.handle_error(Interrupted.new("cancelled")) unless request.response&.finished?
                end
                # No tick: the expired request is complete, and a tick with
                # nothing left to select would sleep out the deadline's
                # remaining interval before the loop reads the answer.
                return nil
              end
              if !open.empty? && !pending
                pending = true
                timer = after(POLL_SECONDS) { pending = false }
                timer.label = :cancel_watch
                timers << timer
              end
              super()
            end
          end

          selector.singleton_class.prepend(watch)
          super
        ensure
          timers&.each(&:cancel)
        end
      end
    end

    # NO ALT-SVC REACHES HTTPX. httpx 1.8.4 parses every response's
    # `Alt-Svc` inside the selector's callback, and its parser never
    # advances past a token that is not name=value (`Alt-Svc: garbage`):
    # the thread spins where neither the deadline nor the cancel watch runs.
    # The header is dropped as the response is built and again from
    # trailers, because a session that opens one connection per call has no
    # use for an alternative service.
    module NoAltSvc
      module ResponseMethods
        def initialize(*)
          super
          @headers.delete("alt-svc")
        end

        def merge_headers(*)
          super
          @headers.delete("alt-svc")
        end
      end
    end


    # THE CLIENT: one httpx session per call — the SSRF
    # filter on every RESOLVED address before the socket opens (so a
    # public name rebound to `10.0.0.1` is refused as `localhost` is), same-
    # site redirects up to the bound with a cross-site one REPORTED, the
    # body streamed chunk by chunk under the wire cap, the SDK's one
    # deadline armed before resolve/connect/TLS, the cancel watch beside
    # it. No pool, no keep-alive, no proxy, no cookies, no body sent.
    class Client
      WIRE_CAP = 5 * 1024 * 1024
      CONNECT_TIMEOUT = 10
      TOTAL_TIMEOUT = 30
      MAX_REDIRECTS = 3
      # THE LONGEST REDIRECT TARGET THE MODEL IS HANDED WHOLE: the common
      # request-line limit (Apache's LimitRequestLine is 8190, nginx's
      # large_client_header_buffers 8k). A presigned URL with a session token
      # runs to thousands of bytes and must stay followable; a target past
      # this no common server accepts, so it is shortened and not offered.
      URL_ACTIONABLE_BYTES = 8190
      # The body kept from a 4xx/5xx: an API's error JSON is the model's to
      # read (openclaw's error-detail cap, smaller).
      ERROR_BODY_BYTES = 512
      REDIRECT_STATUS = (300..399)
      # What `allow_private_network: true` lifts — loopback and RFC 1918,
      # and NOTHING ELSE. httpx consults the safe list FIRST, so anything
      # lifted is admitted whatever else says no: lifting ULA (`fc00::/7`)
      # would admit AWS's IPv6 IMDS `fd00:ec2::254`; link-local (the
      # metadata endpoints), CGNAT (`100.64/10`, Alibaba's
      # `100.100.100.200`), documentation and reserved ranges stay refused.
      LIFTED_RANGES = %w[127.0.0.0/8 ::1/128 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16]
        .map { |range| IPAddr.new(range) }.freeze
      # Honest, so a site's operator can allowlist it; a browser UA is a
      # lie, and rho has a real browser beside this for a page that wants one.
      USER_AGENT = "rho-web-tools/#{VERSION}".freeze
      # claude-code's, verbatim (`utils.ts:279`); no `accept-language`.
      ACCEPT = "text/markdown, text/html, */*".freeze

      attr_reader :allow_private_network, :total_timeout, :connect_timeout

      # `total_timeout:` and `resolver_options:` are the suite's seams: the
      # deadline over `/slow` and a resolver nobody answers, under seconds
      # a test can wait.
      def initialize(allow_private_network: false, total_timeout: TOTAL_TIMEOUT,
                     connect_timeout: CONNECT_TIMEOUT, resolver_options: nil)
        @allow_private_network = allow_private_network == true
        @total_timeout = total_timeout
        @connect_timeout = connect_timeout
        @resolver_options = resolver_options
      end

      # A `Page`, or one of the four errors above — each ONE sentence
      # naming the host and the cause, never the query, never a backtrace.
      # The URL is parsed by the rule before the session is built.
      def get(url)
        uri = UrlRule.parse(url)
        session = build_session(uri)
        begin
          read(session, uri)
        ensure
          session.close
        end
      rescue CancelWatch::Interrupted
        Rho::Runner::ExecutionContext.current.raise_if_cancelled!
      rescue HTTPX::ServerSideRequestForgeryError
        raise Refused.new(private_sentence(uri.hostname), reason: :private_address)
      rescue HTTPX::InsecureRedirectError => error
        raise Redirected.new("redirect: #{uri} → #{shown(error.message)}; web_fetch never follows https to http — " \
                             "call web_fetch with the new url to read it", status: nil, location: whole(error.message))
      rescue HTTPX::TotalRequestTimeoutError
        raise Unreachable, "#{uri.hostname} did not answer within #{seconds(@total_timeout)}"
      rescue HTTPX::ConnectTimeoutError
        raise Unreachable, "#{uri.hostname} did not accept a connection within #{seconds(@connect_timeout)}"
      rescue HTTPX::ResolveError, HTTPX::ResolveTimeoutError
        raise Unreachable, "#{uri.hostname} could not be resolved"
      rescue HTTPX::TLSError
        raise Unreachable, "#{uri.hostname} failed the TLS handshake"
      rescue Errno::ECONNREFUSED
        raise Unreachable, "#{uri.hostname} refused the connection"
      rescue HTTPX::ConnectionError => error
        raise Unreachable, "#{uri.hostname} #{error.message.match?(/refused/i) ? "refused the connection" : "could not be reached"}"
      rescue HTTPX::Error, SystemCallError, IOError => error
        raise Unreachable, "#{uri.hostname} could not be reached (#{error.class.name.split("::").last})"
      end

      def private_sentence(host)
        "#{host} resolves to a private or reserved address; web_fetch reaches public hosts only " \
          "(settings.json \"plugins.rho.web_tools.configuration\": {\"allow_private_network\": true} lifts loopback and RFC 1918)"
      end

      private

        def seconds(value) = "#{value == value.to_i ? value.to_i : value}s"

        def build_session(original)
          session = HTTPX
            .plugin(:ssrf_filter, safe_private_ranges: @allow_private_network ? LIFTED_RANGES : [])
            .plugin(:follow_redirects, max_redirects: MAX_REDIRECTS, follow_insecure_redirects: false,
              redirect_on: ->(location) { UrlRule.same_site?(original, location) })
            .plugin(:stream)
            .plugin(NoAltSvc)
            .plugin(CybrosAgent::HttpDeadline)
            .plugin(CancelWatch)
            .with(timeout: { connect_timeout: @connect_timeout, total_request_timeout: @total_timeout },
              # The SDK's own session sets it: an `HTTPX_DEBUG` line never
              # carries a signed query.
              debug_redact: true,
              headers: { "user-agent" => USER_AGENT, "accept" => ACCEPT },
              persistent: false)
          @resolver_options ? session.with(resolver_options: @resolver_options) : session
        end

        # The stream plugin routes EVERY response's decoded chunks to the
        # ROOT request's one stream, and the root's `response` follows the
        # live hop; the collector reads it on every chunk, so a 302's HTML
        # body ("Redirecting…") never lands in the page.
        def read(session, uri)
          collector = Collector.new(host: uri.hostname, cap: WIRE_CAP)
          stream = session.request("GET", uri.to_s, stream: true)
          request = stream.request
          begin
            stream.each do |chunk|
              collector.take(request.response, chunk)
              Rho::Runner::ExecutionContext.current&.raise_if_cancelled!
            end
          rescue HTTPX::HTTPError => error
            # A 4xx/5xx RAISES after its chunks were delivered
            # (`StreamResponse#each` ends with `raise_for_status`): data.
            return page(uri, request, error.response, collector)
          rescue URI::InvalidURIError
            # httpx parses a hop's `Location` before `redirect_on` is asked,
            # so a server's malformed one raises out of the chain while its
            # 3xx is still the root's live response. httpx raises the same
            # class for another header it cannot parse, and that answer
            # names no Location to blame.
            response = request.response
            raise malformed(uri, response) if malformed_location?(response)

            raise Unreachable, "#{uri.hostname} sent a response header web_fetch cannot parse"
          rescue ArgumentError
            # httpx parses a same-site hop's `Retry-After` after it builds
            # the next request and before it sends it, so a value that is
            # neither seconds nor an HTTP date raises with that hop unsent.
            hop = unsent_hop(request)
            raise unless hop

            raise unparsed_retry_after(uri, hop)
          end
          response = request.response
          halted!(uri, response) if REDIRECT_STATUS.cover?(response.status) && response.headers.key?("location")
          page(uri, request, response, collector)
        end

        # The plugin returns the 3xx `Response` in BOTH halting cases —
        # `redirect_on` false and the bound spent — so the rule is re-run
        # on the returned `Location` to pick the sentence.
        def halted!(uri, response)
          location = URI(response.headers["location"])
          location = response.uri.merge(location) if location.relative?
          if UrlRule.same_site?(uri, location)
            raise Redirected.new("#{uri} redirected #{MAX_REDIRECTS} times without answering; web_fetch follows " \
                                 "at most #{MAX_REDIRECTS} redirects", status: response.status,
              location: whole(location.to_s))
          end

          raise Redirected.new("redirect: #{uri} → #{shown(location.to_s)} (#{response.status}); web_fetch follows " \
                               "redirects on the same site only — call web_fetch with the new url to follow it",
            status: response.status, location: whole(location.to_s))
        rescue URI::InvalidURIError
          # The plugin returns the 3xx that spends the bound without parsing
          # its `Location`, so this parse is the first to meet a malformed one.
          raise malformed(uri, response)
        end

        # True only for a 3xx whose `Location` fails the parse httpx itself
        # runs on it (`URI(...)`, before `redirect_on`).
        def malformed_location?(response)
          return false unless response.respond_to?(:headers) && REDIRECT_STATUS.cover?(response.status)

          location = response.headers["location"]
          return false unless location

          URI(location)
          false
        rescue URI::InvalidURIError
          true
        end

        # The header is dumped into the sentence: its bytes come from a
        # server this tool does not control, and escaped they can neither
        # hide a space nor carry an encoding the sentence cannot join.
        def malformed(uri, response)
          Redirected.new("redirect: #{uri} → #{WebTools.shorten(response.headers["location"].dump, URL_MAX_BYTES)} (#{response.status}); " \
                         "the server's Location is not a valid URL, so web_fetch cannot follow it",
            status: response.status, location: nil)
        end

        # The next hop follow_redirects built and has not sent: the root's
        # `redirect_request`, still idle.
        def unsent_hop(request)
          hop = request.redirect_request
          hop if !hop.equal?(request) && hop.state == :idle
        end

        # The 3xx itself is gone by then (the root's live response is the
        # unsent hop's), so the sentence names the URL that hop would fetch.
        def unparsed_retry_after(uri, hop)
          location = hop.uri.to_s
          Redirected.new("redirect: #{uri} → #{shown(location)}; the server's Retry-After is not a number of seconds " \
                         "or an HTTP date, so web_fetch cannot follow it — call web_fetch with the new url to read it",
            status: nil, location: whole(location))
        end

        # A followable `Location` in a sentence: whole up to the request-line
        # limit, because the model is told to call web_fetch with it.
        def shown(location) = WebTools.shorten(location, URL_ACTIONABLE_BYTES)

        # A server's `Location` as the typed field: whole, or nil when the
        # sentence had to shorten it — a shortened URL is not one to fetch.
        def whole(location) = location.bytesize <= URL_ACTIONABLE_BYTES ? location : nil

        def page(uri, request, response, collector)
          type = response.content_type
          Page.new(url: uri.to_s, final_url: response.uri.to_s, status: response.status,
            media_type: type.mime_type.to_s.downcase, charset: type.charset,
            body: collector.body.freeze, bytes: collector.bytes, redirects: hops(request))
        end

        # HTTPX can replace the root's redirect pointer with the latest
        # request. Its remaining redirect budget records every followed hop.
        def hops(request)
          current = request
          while (follow = current.redirect_request) && !follow.equal?(current)
            current = follow
          end
          request.max_redirects - current.max_redirects
        end

        # WHAT IS KEPT, per response: the first chunk of a response not yet
        # seen checks its `Content-Length` against the cap (at most one
        # chunk — httpx's read buffer — is on the wire); a 3xx WITH a
        # `Location` is a hop and its body is dropped; everything else is
        # counted DECODED (the wall against a gzip bomb) and kept — whole
        # under the cap, or the first 512 bytes of an error.
        class Collector
          attr_reader :bytes, :body

          def initialize(host:, cap:)
            @host = host
            @cap = cap
            @seen = nil
            @counting = false
            @keep = nil
            @body = +"".b
            @bytes = 0
          end

          def take(response, chunk)
            arrived(response) unless response.equal?(@seen)
            return unless @counting

            @bytes += chunk.bytesize
            if @bytes > @cap
              raise TooLarge.new("#{@host} sent more than #{size(@cap)}; web_fetch reads at most #{size(@cap)}",
                bytes: @bytes)
            end

            room = @keep ? @keep - @body.bytesize : chunk.bytesize
            @body << chunk.byteslice(0, room) if room.positive?
          end

          private

            def arrived(response)
              @seen = response
              @counting = !(REDIRECT_STATUS.cover?(response.status) && response.headers.key?("location"))
              return unless @counting

              @body = +"".b
              @bytes = 0
              @keep = response.status >= 400 ? ERROR_BODY_BYTES : nil
              length = Integer(response.headers["content-length"], exception: false)
              return unless length && length > @cap

              raise TooLarge.new("#{@host} answered Content-Length #{size(length)}; web_fetch reads at most " \
                                 "#{size(@cap)}", bytes: 0)
            end

            def size(bytes) = Rho::Runner::Truncation.format_size(bytes)
        end
        private_constant :Collector
    end
  end
end
