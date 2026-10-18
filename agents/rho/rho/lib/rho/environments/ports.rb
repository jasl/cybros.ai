module Rho
  class Environments
    # THE PORTS TABLE: the editor's file-system port per ANCHOR — the
    # conversation whose live members a binding shares — registered by
    # the door's `fs:` member, looked up PER CALL by the runner through
    # the resolver `Toolsets` carries (`ExecutionContext#port`), never a
    # member of the frozen env. A child's copy and a side's fork copy
    # carry the parent's anchor, so their rows find the parent's port
    # with no lookup of their own. Dropped at `:host_ended` (the tools
    # left this machine), on `Unavailable` (the port dropped itself
    # through its callback, said once), and by the door's `fs: null`;
    # every drop is one `fs_port.dropped` line with its reason, and no
    # line ever carries the token. Under the tables' one monitor; the
    # table replaced immutably.
    class Ports
      def initialize(monitor:, log:)
        @monitor = monitor
        @log = log
        @ports = {}.freeze
      end

      # A registration replaces the anchor's port; the old one is dropped
      # as `replaced` (a call in flight on it finishes on it). The SAME
      # registration again — the surface re-asserts every prompt — is a
      # no-op: the held port stands, nothing is logged.
      def register(anchor, url:, token:, read:, write:, client:)
        held = self[anchor]
        return held if held && !held.dropped? && held.same?(url: url, token: token, read: read, write: write, client: client)

        port = nil
        port = Extensions::Environment::FsPort.new(url: url, token: token, read: read, write: write, client: client,
          on_drop: ->(detail) { drop(anchor, reason: "unavailable", port: port, detail: detail) })
        previous = @monitor.synchronize do
          held = @ports[anchor]
          @ports = @ports.merge(anchor => port).freeze
          held
        end
        dropped(anchor, previous, "replaced", nil) if previous
        @log&.info("fs_port.registered", anchor: anchor, client: client, read: port.serves?(:read), write: port.serves?(:write))
        port
      end

      # Drops the anchor's port — only the given one, when `port` names
      # it, so a replaced port dropping late never drops its successor.
      # Answers whether anything left the table.
      def drop(anchor, reason:, port: nil, detail: nil)
        removed = @monitor.synchronize do
          held = @ports[anchor]
          next nil if held.nil? || (port && !held.equal?(port))

          @ports = @ports.except(anchor).freeze
          held
        end
        return false if removed.nil?

        dropped(anchor, removed, reason, detail)
        true
      end

      def [](anchor) = anchor && @monitor.synchronize { @ports[anchor] }

      def live?(anchor) = !self[anchor].nil?

      # The door's and the live table's `fs:` — the flags and the client,
      # nil with no port.
      def description(anchor) = self[anchor]&.describe

      # What the runner's `Toolsets` carries: the per-call lookup by anchor.
      def resolver = ->(anchor) { self[anchor] }

      private

        def dropped(anchor, port, reason, detail)
          port.drop(detail || reason)
          @log&.info("fs_port.dropped", anchor: anchor, reason: reason, client: port.client, detail: detail)
        end
    end
  end
end
