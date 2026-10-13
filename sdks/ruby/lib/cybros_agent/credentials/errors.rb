module CybrosAgent
  module Credentials
    # The persisted credential document is unusable in a way the caller cannot
    # fix by retrying: an unknown format version, or a required field missing.
    # Refused rather than half-read, because guessing at the shape of a
    # credential file is how a live session gets silently discarded.
    class StoreError < CybrosAgent::Error; end

    # The rotation succeeded and the new pair could not be written down. This
    # is deliberately NOT a refresh failure: the previous refresh token is
    # already spent, so the pair now held in memory is the only live credential
    # of this connection. The caller must keep using it — re-running the
    # rotation would present the spent token and revoke the whole family — and
    # must know that a restart will not find it.
    class NotDurable < CybrosAgent::Error; end

    # The persisted document belongs to a different connection than this
    # instance does — a fresh browser ceremony wrote over it. The instance is
    # superseded and must not act: its rotation would replace the new
    # connection's only refresh token with a lineage the kernel has retired,
    # undoing the ceremony with nothing to show for it.
    class ConnectionSuperseded < CybrosAgent::Error; end

    # This connection has no live credential for that plane. Either the branch
    # never produced one (a runner is a delivery address, not a principal) or
    # that plane's authority died while the other survived — which Round D
    # made a normal state rather than a contradiction.
    class PlaneUnavailable < CybrosAgent::Error; end
  end
end
