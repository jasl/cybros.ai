require "protocol/http/body/file"
require "tempfile"

module Rho
  module Extensions
    module Ops
      # THE PICTURE THE TRANSCRIPT ONLY NAMED — a screenshot, a spilled log
      # — read back by the page through this one route, WHERE THE FILE IS:
      # `host` names the followed host whose runner wrote it.
      # This machine's own runner answers from disk through the runner
      # gem's `Files` (the same bytes and classification `files_bytes`
      # uses); a runner elsewhere answers through `Ops.relay` — its
      # `files_bytes` stages the file as a capture, and the capture's
      # bytes are fetched on the member plane and streamed back. No verb:
      # a terminal has `cat` for the local half and `rho relay` +
      # `rho fetch` for the remote.
      #
      # WHAT IS CONFINED IS THE RESPONSE. These bytes land in the one
      # origin that holds the per-boot bearer and renders model output, so
      # an inline answer is limited to a classified type, capped, and
      # served under a policy that cannot become active content — the
      # policy is this daemon's, added here because only the daemon knows
      # the origin it serves into. Anything else is an attachment.
      module Files
        # `default-src 'none'` is the whole point: whatever this is, it may
        # not fetch, script, or frame anything. `frame-ancestors 'self'` lets
        # the console show it in its own viewer and nobody else's.
        BYTES_POLICY = "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; " \
                       "sandbox; frame-ancestors 'self'; base-uri 'none'; form-action 'none'".freeze
        # A relayed read's own clock: a capture over a WAN, not the kernel's
        # default park.
        RELAY_TIMEOUT_MS = 30_000

        class << self
          def register(api)
            api.register_route("GET", "/files/bytes") { |request, ctx| bytes(request, ctx) }
          end

          def bytes(request, ctx)
            query = ControlServer.query(request)
            binding = binding_of(ctx, query["host"])
            runner = binding&.dig(:runner)
            return local(ctx, query, binding) if runner.nil? || ctx.own_runner?(runner)

            remote(ctx, runner, query)
          end

          private

            # The followed host's binding facts, when the page named one.
            def binding_of(ctx, host)
              return nil if host.to_s.empty?

              ctx.host_binding(host)
            end

            # WHERE THE FILE IS, PER CONVERSATION: under the named conversation's root — its record in
            # the store — else the daemon default.
            def local(ctx, query, binding = nil)
              root = conversation_root(ctx, binding) || ctx.environment.root
              if root.nil?
                return Rho::Daemon::Refusal.new(status: 409, code: "environment_unset",
                  message: "This daemon has nowhere to read from yet")
              end

              answer = Rho::Runner::Files.bytes(root: root, path: query["path"], download: query["download"] == "1")
              return [answer.status, answer.body] unless answer.ok?

              Protocol::HTTP::Response[answer.status, policed(answer.headers), [answer.body]]
            end

            def conversation_root(ctx, binding)
              host = binding&.fetch(:host)
              return nil unless host&.outlives_turn?

              ctx.environments.binding_for(host.public_id)&.root
            end

            # The runner's `files_bytes` names the file and the run stages
            # it; the link's bytes come back on the member plane into a
            # spool and go out as a file body under the same headers a local
            # read carries. A request that did not complete relays as the
            # tool's error — a missing file is the runner's `No such file`.
            def remote(ctx, runner, query)
              path = query["path"].to_s
              return Rho::Daemon::Refusal.malformed("path is required") if path.empty?

              relayed = Ops.relay(ctx, runner, Rho::Runner::Tools::FilesBytes::NAME, { "path" => path }, RELAY_TIMEOUT_MS)
              return relayed if relayed in Rho::Daemon::Refusal

              link = Array(relayed.detail.content).find { |block| block["type"] == "resource_link" }
              return relay_refusal(relayed.detail) if link.nil?

              stream_capture(ctx, link, query["download"] == "1")
            end

            # The tool RAN and refused (absent, a directory, unreadable): the
            # runner's own words under one code; a request that never
            # completed relays the task's error key.
            def relay_refusal(detail)
              if detail.task.result&.dig("is_error")
                return Rho::Daemon::Refusal.new(status: 404, code: "not_readable", message: detail.output.to_s)
              end

              key = detail.task.error&.dig("key") || detail.task.status
              Rho::Daemon::Refusal.new(status: 502, code: "runner_unreachable", message: "runner could not answer: #{key}")
            end

            def stream_capture(ctx, link, download)
              ctx.member_plane(require_workspace: false) do |client, _workspace_public_id|
                spool = Tempfile.new("rho-files", binmode: true)
                client.uploads.bytes(link.fetch("uri").delete_prefix(CybrosAgent::Api::ResourceLink::URI_PREFIX), spool)
                spool.flush
                file = File.open(spool.path, "rb")
                spool.close!
                located = Rho::Runner::Files::Located.new(path: link.fetch("name"), size: file.size,
                  type: Rho::Runner::Files.classify(link.fetch("name")))
                inline = !download && Rho::Runner::Files::INLINE_TYPES.key?(File.extname(link.fetch("name")).downcase)
                headers = policed(Rho::Runner::Files.headers_for(located, inline)).except("content-length")
                Protocol::HTTP::Response[200, headers, Protocol::HTTP::Body::File.new(file)]
              end
            end

            def policed(headers) = headers.merge("content-security-policy" => BYTES_POLICY)
        end
      end
    end
  end
end
