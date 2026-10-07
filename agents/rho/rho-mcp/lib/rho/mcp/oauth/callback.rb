require "async"
require "async/http/endpoint"
require "async/http/server"
require "erb"
require "protocol/http/response"
require "uri"

module Rho
  module Mcp
    module Oauth
      # THE LOOPBACK LISTENER: `Async::HTTP` —
      # rho's ONE HTTP server library, no hand-parsed HTTP/1 — bound on
      # `127.0.0.1` (RFC 8252 §7.3) at an
      # ephemeral port unless the row fixes one, `/callback`, inside the
      # CLI process for the life of one login. The port is knowable before
      # the flow by the daemon's own trick (`Endpoint#bound`), so the
      # redirect URI names it before the browser opens. The handler pushes
      # what arrived onto a queue the verb pops with a deadline: `code`,
      # `state` and `iss` (the 3-element return opts into the gem's issuer
      # check); an `error` answer is kept on the listener for the verb's
      # sentence — with the `iss` beside it (the verb compares the issuer BEFORE it quotes anything the answer said); the gem raises
      # "did not return an authorization code" and checks nothing else on
      # that path; a stray path (`/favicon.ico`) is 404 and keeps waiting;
      # every reflected value passes `html_escape`. Under `--no-browser`
      # the same queue is also fed by ONE line pasted to stdin — the
      # redirected URL, bounded — whichever arrives first.
      class Callback
        PATH = "/callback".freeze
        HOST = "127.0.0.1".freeze
        DEFAULT_WAIT_SECONDS = 300
        # codex's `MAX_CALLBACK_BYTES`: a pasted line longer than a URL is
        # not a callback.
        MAX_PASTE_BYTES = 8192
        CLOSE_JOIN_SECONDS = 2
        STARTUP_SECONDS = 5
        HTML = { "content-type" => "text/html; charset=utf-8" }.freeze

        attr_reader :port, :error, :error_description, :iss

        def initialize(port: 0, seconds: DEFAULT_WAIT_SECONDS)
          @requested_port = port || 0
          @seconds = seconds
          @queue = Thread::Queue.new
          @port = nil
          @error = nil
          @error_description = nil
          @iss = nil
          @timed_out = false
        end

        # Binds now (the port is the redirect URI's) and starts the accept
        # loop on its own thread.
        def bind
          @endpoint = Async::HTTP::Endpoint.parse("http://#{HOST}:#{@requested_port}")
          @bound = @endpoint.bound
          @port = @bound.sockets.first.local_address.ip_port
          # The daemon's own shape (`ControlServer#run`): a reactor on its
          # own thread, its scheduler captured for `close`'s interrupt —
          # awaited here, so a `close` that follows `bind` at once still
          # finds a reactor to interrupt — `wait` re-raising a stillborn
          # accept loop into the thread.
          ready = Thread::Queue.new
          @thread = Thread.new do
            Async do
              @scheduler = Fiber.scheduler
              ready << true
              Async::HTTP::Server.for(@bound, protocol: @endpoint.protocol, scheme: @endpoint.scheme) do |request|
                handle(request)
              end.run
            end.wait
          end
          @thread.report_on_exception = false
          ready.pop(timeout: STARTUP_SECONDS)
          self
        end

        def redirect_uri = "http://#{HOST}:#{@port}#{PATH}"

        # `[code, state, iss]` from the first callback that arrives — the
        # browser's, or the pasted line's — or nil past the deadline.
        def wait(paste: nil)
          reader = paste ? Thread.new { read_paste(paste) } : nil
          result = @queue.pop(timeout: @seconds)
          @timed_out = result.nil?
          result
        ensure
          reader&.kill
        end

        def timed_out? = @timed_out

        # The daemon's order: interrupt the reactor, join the thread, then
        # close the sockets — a socket closed under a thread still inside
        # `accept` is a deadlock, so an accept loop that outlives the join
        # keeps its sockets (the process's exit frees them).
        def close
          @scheduler&.interrupt
          @thread&.join(CLOSE_JOIN_SECONDS)
          @bound&.close unless @thread&.alive?
          nil
        end

        private

          def handle(request)
            path, query = request.path.to_s.split("?", 2)
            return Protocol::HTTP::Response[404, HTML, ["not found"]] unless path == PATH

            params = URI.decode_www_form(query.to_s).to_h
            if params.key?("error")
              record(params)
              @queue << [nil, params["state"], params["iss"]]
              return page("rho: the authorization server answered #{params["error"]}: #{params["error_description"]} " \
                          "— you can close this tab")
            end

            @iss = params["iss"]
            @queue << [params["code"], params["state"], params["iss"]]
            page("rho: you are signed in — you can close this tab")
          end

          # What the answer said, kept for the verb's sentence.
          def record(params)
            @error = params["error"]
            @error_description = params["error_description"]
            @iss = params["iss"]
          end

          def page(text)
            Protocol::HTTP::Response[200, HTML, ["<!doctype html><title>rho</title><p>#{ERB::Util.html_escape(text)}</p>"]]
          end

          # The pasted redirect URL, its query read as the browser's would be.
          def read_paste(input)
            line = input.gets(MAX_PASTE_BYTES)
            return if line.nil?

            query = line.strip.split("?", 2).fetch(1, "")
            params = URI.decode_www_form(query).to_h
            record(params)
            @queue << [params["code"], params["state"], params["iss"]]
          rescue StandardError
            nil
          end
      end
    end
  end
end
