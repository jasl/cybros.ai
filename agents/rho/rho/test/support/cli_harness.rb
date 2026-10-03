require "json"
require "net/http"
require "socket"
require "stringio"
require "tmpdir"

# WHAT EVERY CLI TEST STANDS ON: a `Rho::Cli::Terminal` over a temporary
# home that prints into a StringIO (and its bare `Rho::Core` for the
# primitives), a real daemon when the verb needs one, and
# scripted daemons for the answers a verb must survive. Shared by
# cli_test (the core verbs) and the per-extension command tests under
# test/extensions so a test moves between them without a helper moving too.
module RhoTest
  module CliHarness
    def setup
      @root = Dir.mktmpdir("rho-cli-lib")
      @out = StringIO.new
      @daemons = []
      @sockets = []
    end

    def teardown
      @daemons.each { |daemon| daemon.stop if daemon.running? }
      @sockets.each { |socket| socket.close unless socket.closed? }
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    end

    def home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root)

    def cli = Rho::Cli::Terminal.new(home: home, out: @out)

    # The primitives alone: a document in, a document out, nothing printed.
    def core = Rho::Core.new(home: home)

    def boot(oauth: NexusDoubles::FakeOAuth.new, api: NexusDoubles::FakeAgentApi.new, **options)
      daemon = Rho::Daemon.boot(
        home: home,
        device_flow: CybrosAgent::DeviceFlow::Client.new(
          base_url: "https://nexus.example", transport: oauth, sleeper: ->(_seconds) { nil }
        ),
        api_transport: api, **options
      )
      @daemons << daemon
      daemon
    end

    def announce(endpoint:, version: Rho::Daemon::ANNOUNCEMENT_VERSION)
      home.prepare
      Rho::StateFile.new(home.announcement_path).write(
        {
          "version" => version,
          "endpoint" => endpoint,
          "bearer" => "x",
          "pid" => Process.pid,
        }
      )
    end

    # A daemon whose control surface is a table: each route answers its
    # [status, document] pairs in turn, the last repeating, so a verb that
    # polls (kill) can be walked through a change of state.
    def routed_endpoint(routes) = recording_routed_endpoint(nil, routes)

    # The table, KEEPING WHAT WAS SENT (every request whole, the body read
    # to its length) — for a verb whose assertion is the body it posted.
    # A positional recorder, because a braceless string-keyed table would
    # ride as keywords beside a `seen:` option.
    def recording_routed_endpoint(seen, routes)
      served = Hash.new(0)
      serve do |client, request|
        request = with_body(client, request) if seen
        seen << request if seen
        line = request.lines.first.to_s
        key = routes.keys.find { |candidate| line.start_with?(candidate) }
        if key
          answers = routes.fetch(key)
          status, document = answers[[served[key], answers.length - 1].min]
          served[key] += 1
          answer(client, status, document)
        elsif line.start_with?("GET /healthz")
          answer(client, 200, "status" => "ok", "version" => Rho::VERSION,
            "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION)
        else
          answer(client, 404, "error" => { "code" => "not_found", "message" => line.strip })
        end
      end
    end

    # KEEPS WHAT WAS SENT. `routed_endpoint` scripts answers and forgets
    # the question, which is fine until the assertion IS the question —
    # a flag that never left the CLI would pass every scripted test.
    def recording_endpoint(seen, status, document)
      serve do |client, request|
        seen << with_body(client, request)
        if request.lines.first.to_s.start_with?("GET /healthz")
          answer(client, 200, "status" => "ok", "version" => Rho::VERSION,
            "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION)
        else
          answer(client, status, document)
        end
      end
    end

    # ONE readpartial IS ONE PACKET, and a POST's body often lands in the
    # next one — a recorder that keeps only what arrived first sees the
    # headers, asserts on an empty body, and passes or fails by timing.
    def with_body(client, request)
      head, _, body = request.partition("\r\n\r\n")
      length = head[/^Content-Length:\s*(\d+)/i, 1].to_i
      body = +body.to_s
      body << client.readpartial(4096) while body.bytesize < length
      "#{head}\r\n\r\n#{body}"
    end

    # One connection at a time, closed after each answer. The first is always
    # /healthz; the block decides what happens to the rest, including a block
    # that answers nothing and lets the socket close under the caller.
    def serve(&handler)
      server = TCPServer.new("127.0.0.1", 0)
      @sockets << server
      Thread.new do
        loop do
          client = server.accept
          request = client.readpartial(4096)
          handler.call(client, request)
          client.close
        end
      rescue IOError, Errno::EBADF, Errno::ECONNRESET, Errno::EPIPE
        nil
      end
      "http://127.0.0.1:#{server.addr[1]}"
    end

    # A String document is served as the pushed channel's own bytes — a
    # scripted `/loops/follow` stream, frames and all — never as JSON.
    def answer(client, status, document)
      type, body = document.is_a?(String) ? ["text/event-stream", document] : ["application/json", JSON.generate(document)]
      client.write("HTTP/1.1 #{status} #{status == 200 ? "OK" : "Unauthorized"}\r\n" \
        "Content-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n" \
        "Connection: close\r\n\r\n#{body}")
    end

    def pending_start
      {
        "phase" => "pending",
        "user_code" => "BCDF-GHJK",
        "verification_uri" => "https://nexus.example/oauth/device",
        "verification_uri_complete" => "https://nexus.example/oauth/device?user_code=BCDF-GHJK",
      }
    end

    # A daemon whose answers are a script: /healthz is alive, /device/start
    # answers `start`, and the nth /status answers `statuses[n]` (the last
    # entry repeats). What a verb does with each answer is the thing under
    # test.
    def scripted_endpoint(start:, starts: nil, statuses: [],
      health: {
        "status" => "ok",
        "version" => Rho::VERSION,
        "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION,
      })
      polls = 0
      begins = 0
      serve do |client, request|
        if request.start_with?("GET /healthz")
          answer(client, 200, health)
        elsif request.start_with?("POST /device/start")
          # `starts:` scripts a per-attempt sequence of [status, document]
          # pairs (the last repeats); `start:` is the plain one-answer form.
          if starts
            status, document = starts[[begins, starts.length - 1].min]
            begins += 1
            answer(client, status, document)
          else
            answer(client, 200, start)
          end
        else
          # A poll against a script with no statuses is the scripted test's own
          # bug; a loud 500 beats a nil-deref crashing the serve thread.
          status, document = statuses.empty? ? [500, {}] : statuses[[polls, statuses.length - 1].min]
          polls += 1
          answer(client, status, document)
        end
      end
    end

    # Answers the liveness probe once, then is gone: every later caller finds a
    # socket that closes without answering, which is what a daemon that died
    # between the two requests leaves behind.
    def one_shot_endpoint
      served = 0
      serve do |client, _request|
        served += 1
        answer(client, 200, {
          "status" => "ok",
          "version" => Rho::VERSION,
          "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION,
        }) if served == 1
      end
    end

    # Alive, and answering every route with a page — the SPA fallback's shape.
    def page_serving_endpoint
      serve do |client, request|
        if request.start_with?("GET /healthz")
          next answer(client, 200, {
            "status" => "ok",
            "version" => Rho::VERSION,
            "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION,
          })
        end

        body = "<!doctype html><title>rho</title>"
        client.write("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" \
          "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      end
    end

    # Alive, and refusing the bearer this client holds.
    def refusing_endpoint
      serve do |client, request|
        if request.start_with?("GET /healthz")
          next answer(client, 200, {
            "status" => "ok",
            "version" => Rho::VERSION,
            "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION,
          })
        end

        answer(client, 401, { "error" => { "code" => "unauthorized", "message" => "Unauthorized" } })
      end
    end

    # The budget granted to the network layer is the defect this pins, so it is
    # read where the CLI hands it over.
    def capture_read_timeouts
      granted = []
      original = Net::HTTP.method(:start)
      replacement = lambda do |*arguments, **options, &block|
        granted << options[:read_timeout]
        original.call(*arguments, **options, &block)
      end

      original_verbose = $VERBOSE
      begin
        $VERBOSE = nil
        Net::HTTP.define_singleton_method(:start, replacement)
      ensure
        $VERBOSE = original_verbose
      end

      yield
      granted
    ensure
      if original
        restore_verbose = $VERBOSE
        begin
          $VERBOSE = nil
          Net::HTTP.define_singleton_method(:start, original)
        ensure
          $VERBOSE = restore_verbose
        end
      end
    end
  end
end
