require "async"
require "async/http/endpoint"
require "async/http/server"
require "ipaddr"
require "json"
require "protocol/http/response"
require "uri"

module Rho
  # The daemon's local HTTP surface, deliberately outside the frozen `rho/v1`
  # face: these are control-plane routes a client uses to bring the daemon up,
  # not product routes a third party consumes.
  #
  # async-http, on a fiber reactor: the surface is about to carry long-lived
  # connections — streaming and the wake channel's WebSocket — and one thread
  # per connection is the wrong shape for a daemon that should idle at nearly
  # no cost. Not falcon, because rho already owns everything falcon would
  # bring: this class is the router, `Rho::StaticFiles` is the static handler, the
  # Host check below is the security layer, and Rack would sit under all of it
  # doing nothing.
  class ControlServer
    LOOPBACK_HOSTS = %w[localhost].freeze
    # How long shutdown waits for in-flight requests before abandoning them.
    # It must be bounded: the listener closes first, so waiting forever would
    # keep the home claimed while the announced port is already free for
    # anyone to take — and one local client stalling mid-request would defeat
    # SIGTERM.
    DRAIN_DEADLINE = 5
    STARTUP_POLL = 0.01
    # How long a reactor gets to fail on the way up before we call it started.
    # The listening socket already exists (see #initialize), so this is not a
    # wait for readiness — it is a window in which a server that cannot run at
    # all gets to say so, and its error becomes this boot's error.
    #
    # It is a fixed window and not a probe because there is nothing to probe:
    # the socket accepts at the TCP level from its own backlog whether or not
    # the reactor ever reached it, so a connection proves nothing. A stillborn
    # `run` raises on its first tick, well inside this; a healthy boot pays it
    # once, alongside the file IO and locks it already pays.
    STARTUP_GRACE = 0.05
    JSON_TYPE = "application/json".freeze
    # Injectable so a test can drive the router without an accept loop; the
    # daemon never passes anything else.
    DEFAULT_SERVER = Async::HTTP::Server

    # A route table maps [method, path] to a handler answering [status, body].
    def initialize(bind:, port:, routes:, static_root: nil, server_class: DEFAULT_SERVER)
      @routes = routes
      # A PATH THE TABLE OWNS IS NEVER A DEEP LINK, whatever verb arrives.
      # Falling through to the index answered a probe of a control route with
      # 200 text/html — which is how a credential leaked out of an untested
      # path once.
      @claimed_paths = routes.keys.map { |(_verb, path)| path }.to_set
      # THE ONE DOOR INTO THIS REACTOR FROM ANOTHER THREAD.
      #
      # It was inbound-only: the scheduler is captured inside the Async block
      # and read by `stop` alone, so nothing outside could put work on it. But
      # a fiber can only be spawned from inside its own reactor, and rho now
      # has outbound work that wants to be one — a feed following a run, which
      # is mostly waiting on IO and would cost a whole thread to do that in.
      #
      # A Thread::Queue is the door and needs nothing new: pushing is
      # thread-safe by definition, and popping YIELDS under the scheduler
      # rather than blocking it, so a reactor waiting on an empty inbox keeps
      # serving. Verified rather than assumed — a reactor with a blocked pop
      # ticks at full rate.
      @inbox = Thread::Queue.new
      @static_root = static_root
      @bind = bind
      @server_class = server_class
      # Bound here, not when the reactor starts: an ephemeral port has to be
      # knowable before #run so the announcement can name it without racing
      # the accept loop. WEBrick gave this for free by binding in its
      # constructor; async-http binds when asked, so we ask now.
      @endpoint = Async::HTTP::Endpoint.parse("http://#{authority(bind, port)}")
      @bound = @endpoint.bound
    end

    def port = @bound.sockets.first.local_address.ip_port

    # Called on this server's reactor when extension routes change. The socket
    # and outstanding responses stay on the same server.
    def configure(routes:, static_root:)
      @routes = routes
      @claimed_paths = routes.keys.map { |(_verb, path)| path }.to_set
      @static_root = static_root
    end

    # A request body is JSON or it is nothing. The bound is small on purpose:
    # this surface is local control, every verb on it is a short command, and
    # an unbounded read on a loopback socket is still a way for one bad client
    # to make a daemon hold a request-sized string per connection.
    MAX_BODY_BYTES = 64 * 1024

    MalformedBody = Class.new(Error)

    def self.json_body(request)
      # Async bodies yield chunks; `each` also closes the consumed body,
      # releasing a persistent connection for its next browser request.
      raw = +"".b
      request.body&.each do |chunk|
        raise MalformedBody, "the request body exceeds #{MAX_BODY_BYTES} bytes" if
          raw.bytesize + chunk.bytesize > MAX_BODY_BYTES

        raw << chunk
      end
      return {} if raw.empty?
      # A SIMPLE REQUEST IS A CROSS-ORIGIN REQUEST. `text/plain` is
      # CORS-safelisted, so without this check a page the operator merely
      # visited can POST into this router with no preflight and no consent —
      # arming `/unlock`'s global lockout window on every rho on the machine,
      # for one. Demanding the type makes every write here preflighted, and
      # this router answers no OPTIONS, so the request never arrives.
      type = Array(request.headers["content-type"]).first.to_s.split(";").first.to_s.strip
      raise MalformedBody, "the request body must be sent as #{JSON_TYPE}" unless type == JSON_TYPE
      parsed = JSON.parse(raw)
      raise MalformedBody, "the request body must be a JSON object" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise MalformedBody, "the request body is not JSON"
    end

    # THE QUERY STRING, which the router splits off and discards — the
    # table is verb-and-path exact, so a route that needs one argument
    # reads it here rather than becoming a POST that is really a read.
    #
    # Flat, single-valued, and never raises: a repeated key keeps the
    # LAST, and a malformed pair is dropped. Nothing here is a boundary,
    # so a caller sending nonsense gets a missing argument and the
    # handler's own refusal, which says more than a parse error would.
    def self.query(request)
      raw = request.path.split("?", 2)[1].to_s
      raw.split("&").each_with_object({}) do |pair, params|
        key, value = pair.split("=", 2)
        next if key.nil? || key.empty?

        decoded_key = unescape(key)
        decoded_value = unescape(value.to_s)
        next if decoded_key.nil? || decoded_value.nil?

        params[decoded_key] = decoded_value
      end
    end

    # `URI` rather than `CGI`, which Ruby 4.0 removed. A percent-escape
    # this cannot decode yields nil and the pair is dropped.
    def self.unescape(text)
      URI.decode_www_form_component(text)
    rescue ArgumentError
      nil
    end

    # Runs `task` as a child of this server's reactor, from any thread. Safe
    # before `run`: the queue buffers, and the drain starts with the reactor.
    #
    # There is no handle back. A caller that needs to stop its work owns a way
    # to ask it to — a feed has `stop` — because a task handle would be a
    # second way to end something, reachable from a thread that may not stop
    # it safely.
    def spawn(&task)
      @inbox << task
      self
    end

    def run
      @thread = Thread.new do
        # `.wait` on the completed task is what re-raises its failure into this
        # thread: the reactor otherwise logs an unhandled task error and lets
        # the thread end cleanly, which would turn a diagnosable boot failure
        # into a silent one.
        Async do |reactor|
          # Captured for #stop, which runs on the caller's thread: a task may
          # only be stopped from inside its own reactor, but a scheduler's
          # interrupt is the thread-safe door in — it is how a signal handler
          # unwinds one.
          @scheduler = Fiber.scheduler
          # TRANSIENT, so waiting on the inbox cannot be the reason this
          # reactor is alive. Without that a stillborn accept loop stops
          # failing the boot: the thread stays up on the drain alone, the
          # startup grace sees it alive, and a daemon reports success while
          # holding the installation's lock with nothing listening. The
          # existing boot test found exactly that.
          reactor.async(transient: true) { drain_inbox(reactor) }
          @server_class.new(
            method(:handle), @bound, protocol: @endpoint.protocol, scheme: @endpoint.scheme
          ).run
        end.wait
      end
      @thread.report_on_exception = false

      # The accept loop dying on the way up is this boot's failure, and it must
      # arrive as that server's own error: a daemon that reported success here
      # would hold the home's boot lock with nothing listening, and the next
      # one would be refused by a corpse.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STARTUP_GRACE
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        unless @thread.alive?
          # Re-raises whatever killed it, which is the diagnosis worth having;
          # the generic message below is only for a thread that ended without
          # one.
          @thread.join
          raise Error, "the control server stopped before it began listening"
        end

        sleep STARTUP_POLL
      end
      self
    end

    def stop
      @scheduler&.interrupt
      warn "rho: drain deadline reached; abandoning stalled connections" unless drained?
      @bound.close
      nil
    end

    private

      # Each entry becomes its OWN child task, so one spawned failure cannot
      # take the drain — or the accept loop — down with it. A task that raises
      # is the reactor's to log; this loop must survive to admit the next one.
      def drain_inbox(reactor)
        while (task = @inbox.pop)
          reactor.async { task.call }
        end
      end

      # IPv6 literals are bracketed in an authority, and a bare `::` would
      # otherwise be read as a host/port separator.
      def authority(bind, port)
        bind.include?(":") ? "[#{bind}]:#{port}" : "#{bind}:#{port}"
      end

      def drained?
        return true if @thread.nil?

        !@thread.join(DRAIN_DEADLINE).nil?
      rescue StandardError
        # The accept loop already failed and #run has surfaced why; joining it
        # again would only re-raise that, and teardown must still finish
        # releasing the lock.
        true
      end

      def handle(request)
        return json(421, error: { code: "misdirected", message: "Misdirected request" }) unless
          loopback_host?(request)

        # HEAD runs the GET handler and drops the body, so a verb-exact table
        # must map it or `curl -I` — an ordinary way to probe readiness — gets
        # a 404.
        head = request.method == "HEAD"
        method = head ? "GET" : request.method
        path = request.path.split("?").first.to_s
        handler = @routes[[method, path]]
        response =
          if handler
            # A HANDLER MAY ANSWER A RESPONSE ITSELF. Everything here is a
            # `[status, body]` pair rendered as JSON — except a stream,
            # whose body is written to over time and cannot be a value the
            # renderer serializes once.
            answer = handler.call(request)
            answer.is_a?(Protocol::HTTP::Response) ? answer : json(*answer)
          elsif method == "GET"
            # GET only. The fallback exists so a deep link opened by hand lands
            # somewhere (see `static`), which is a statement about navigation —
            # it says nothing about a POST to a path no route claims, and
            # answering one with the SPA's index tells a client its unrouted
            # write succeeded.
            if @claimed_paths.include?(path)
              json(405, error: { code: "method_not_allowed", message: "Not allowed" })
            else
              static(path)
            end
          else
            json(404, error: { code: "not_found", message: "Not found" })
          end
        # HEAD KEEPS THE LENGTH. Dropping the body made the server recompute
        # `content-length` as 0 on every route, so `curl -I` — the reason HEAD
        # is answered at all — reported every asset and every JSON document as
        # empty.
        head ? headless(response) : response
      rescue StandardError => error
        # A control-plane failure must not take the daemon down with it, and
        # must not describe itself: the description is the one thing likely to
        # quote something private.
        # THE CLASS AND WHERE IT CAME FROM. The message stays out — that is
        # the part likely to quote something private — but the first
        # backtrace frame is our own source, and a 500 that says only its
        # class is a 500 nobody can diagnose.
        warn "rho: control request failed (#{error.class}) at #{error.backtrace&.first}"
        json(500, error: { code: "internal_error", message: "Internal error" })
      end

      # DNS rebinding is the one attack a loopback bind does not stop by itself:
      # an attacker points their own hostname at this address, the browser then
      # treats http://evil.example:PORT as same-origin, and their script can
      # read our responses — including the local bearer we hand the page. A
      # browser always sends the name it dialled, so the authority is the
      # signal.
      #
      # Accepted: loopback names, and the address the operator explicitly asked
      # us to listen on — otherwise a deliberate LAN bind would refuse every
      # request including the operator's own. A wildcard bind has no address to
      # compare against, so the check cannot apply there; that is part of what
      # the per-boot transport assertion acknowledges.
      def loopback_host?(request)
        return true if Daemon::WILDCARD_BINDS.include?(@bind)

        host = hostname(request.authority.to_s)
        return true if host.empty?

        LOOPBACK_HOSTS.include?(host) || host == @bind || loopback_address?(host)
      end

      # An IPv6 literal is bracketed, so splitting on the first colon would
      # take it apart rather than separating host from port.
      def hostname(header)
        value = header.strip.downcase
        return value[/\A\[([^\]]*)\]/, 1].to_s if value.start_with?("[")

        value.split(":").first.to_s
      end

      def loopback_address?(host)
        IPAddr.new(host).loopback?
      rescue IPAddr::InvalidAddressError
        false
      end

      # The webui is a plain SPA: real files if they exist, otherwise the
      # index, so a deep link opened by hand still lands somewhere. Reached
      # only for GET and HEAD — see `handle`.
      def static(path)
        return json(404, error: { code: "not_found", message: "Not found" }) if @static_root.nil?

        asset = @static_root.resolve(path)
        return json(404, error: { code: "not_found", message: "Not found" }) if asset.nil?

        Protocol::HTTP::Response[200, static_headers(asset), [asset.body]]
      end

      # NOSNIFF ALWAYS, AND HTML NEVER IN A FRAME. The document this mount
      # serves carries the per-boot bearer, so a browser guessing a served
      # file into a script context, or another page framing it, is a
      # credential boundary rather than a lint. Both headers were the
      # predecessor's and both were lost.
      def static_headers(asset)
        headers = {
          "content-type" => asset.content_type,
          "cache-control" => asset.cache_control,
          "x-content-type-options" => "nosniff",
        }
        return headers unless asset.content_type.start_with?("text/html")

        headers.merge(
          "x-frame-options" => "DENY",
          "referrer-policy" => "no-referrer",
          # THE PAGE RENDERS MODEL OUTPUT, which is downstream of files, web
          # pages and tool results a remote party influences — the standing
          # prompt-injection surface of this product. One rendering bug that
          # executes script runs same-origin against a control surface whose
          # every route runs shell commands. A policy does not eliminate that;
          # it is the difference between a markdown-passthrough bug and a
          # shell. `script-src 'self'` is affordable only because the document
          # no longer carries an inline bootstrap — do not re-introduce one.
          # `style-src` concedes inline: every bundler emits it, and a style
          # injection reads no credential.
          "content-security-policy" =>
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " \
            "img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; " \
            "object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
        )
      end

      def headless(response)
        length = response.body&.length
        headers = response.headers.to_h
        headers["content-length"] = length.to_s if length
        Protocol::HTTP::Response[response.status, headers, []]
      end

      # NOSNIFF HERE TOO, not only on the static mount: a JSON body a browser
      # decides to treat as HTML is the oldest version of this bug, and every
      # document this router returns is one an unauthenticated caller can ask
      # for.
      def json(status, body)
        Protocol::HTTP::Response[
          status,
          { "content-type" => JSON_TYPE, "x-content-type-options" => "nosniff" },
          [JSON.generate(body)]
        ]
      end
  end
end
