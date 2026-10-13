require "protocol/http/body/file"
require "tempfile"

module Rho
  module Extensions
    module Ops
      # THE ONE BYTES READ, proxied: an upload's bytes — a
      # capture a result named, an attachment of a followed conversation —
      # fetched on the member plane by the upload's own rule (the creator,
      # or a reader of a row that names it) and streamed back whole. The
      # SDK streams into a spool on disk, never a daemon-sized buffer, and
      # the answer is the spool as a file body; a kernel 404 relays as
      # itself through the route's own rescue. No verb but `rho fetch`: a
      # debug verb, one output, a person redirects. THE TWO NAMED
      # REPRESENTATION READS ride the same route under `kind`:
      # `thumbnail` or `preview` is the SDK's verb of that name, the same
      # spool; the kernel's `representation_unavailable` relays as itself.
      module Uploads
        MEDIA = "application/octet-stream".freeze
        # The SDK's three attachment reads by the query's name.
        KINDS = %w[bytes thumbnail preview].freeze

        def self.register(api)
          api.register_route("GET", "/uploads/bytes") { |request, ctx| bytes(request, ctx) }
        end

        def self.bytes(request, ctx)
          query = ControlServer.query(request)
          public_id = query["public_id"].to_s
          return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

          kind = query.fetch("kind", "bytes").to_s
          return Rho::Daemon::Refusal.malformed("kind must be one of #{KINDS.join(", ")}") unless KINDS.include?(kind)

          ctx.member_plane(require_workspace: false) do |client, _workspace_public_id|
            spool = Tempfile.new("rho-fetch", binmode: true)
            client.uploads.public_send(kind, public_id, spool)
            spool.flush
            file = File.open(spool.path, "rb")
            # Unlinked at once: the open handle keeps the bytes for the
            # body's read, and nothing is left behind on disk after it.
            spool.close!
            # The length is the body's own (`Body::File#length`); the server
            # stamps the header from it.
            Protocol::HTTP::Response[200, { "content-type" => MEDIA }, Protocol::HTTP::Body::File.new(file)]
          end
        end
      end
    end
  end
end
