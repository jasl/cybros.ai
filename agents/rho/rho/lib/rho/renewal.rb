require "cybros_agent"

module Rho
  # Keeping a long-lived connection alive.
  #
  # Renewal is proactive rather than only reactive because reactive alone is
  # not enough twice over: a `401` is one undifferentiated type, so every
  # fenced credential would cost a failed request before anyone noticed, and a
  # daemon that simply sits still — no tasks, no calls — would lose its session
  # to the kernel's inactivity window without ever making the request that
  # would have told it.
  #
  # The cadence is rho's own, deliberately. The kernel decides when a lineage
  # lapses; rho decides how often it renews, and the only thing coupling them
  # is that the second must stay comfortably inside the first. Importing the
  # kernel's constants would make a client's behaviour depend on a number it
  # cannot read, for no benefit.
  #
  # What rho assumes, as of this writing: an access token lives about two
  # weeks, and a lineage lapses after a month or so without a rotation.
  # Renewing once less than a week remains gives roughly weekly rotation —
  # comfortably inside that window, with a week of slack for a Nexus that
  # cannot be reached.
  #
  # Nothing expires a working connection on a calendar — the kernel has no
  # absolute horizon — so a daemon that keeps renewing keeps its session
  # indefinitely. What still ends a connection is revocation, a reuse cascade,
  # or lapsing after a month of not renewing at all; none of those can be
  # retried past, and rho's job is to say so plainly rather than retry into a
  # wall.
  class Renewal
    RENEWAL_LEAD = 7 * 24 * 60 * 60
    DEFAULT_INTERVAL = 60 * 60

    def initialize(oauth:, clock: -> { Time.now }, on_event: nil)
      @oauth = oauth
      @clock = clock
      @on_event = on_event
    end

    def due?
      @clock.call >= (@oauth.expires_at - RENEWAL_LEAD)
    rescue CybrosAgent::Error
      false
    end

    # One renewal attempt. Returns what happened, because the daemon reports it
    # rather than logging it into the dark.
    #
    # `verify:` is the other reason to act. A resource `401` is undifferentiated
    # — a probe cannot tell a revoked lineage from any other
    # refusal, and must not spend a single-use token trying. The rotation
    # endpoint CAN tell: RFC 6749 makes it answer `invalid_grant` for a lineage
    # that is gone. So it is the one oracle in the protocol, this class is its
    # only caller, and a refusal reported from anywhere reaches the answer
    # through here rather than by each call site guessing.
    def run_once(verify: false)
      return :not_due unless due? || verify

      @oauth.refresh
      notify(:renewed)
    rescue CybrosAgent::DeviceFlow::AuthorizationLostError, CybrosAgent::Credentials::ConnectionSuperseded
      # Terminal. The lineage is gone — by revocation, by a reuse cascade, or by
      # the inactivity reap — and no retry can bring it back. A human has to
      # connect again.
      notify(:lost)
    rescue CybrosAgent::Credentials::NotDurable
      # The rotation happened and could not be written down. The pair in memory
      # is the only live credential, so it must keep being used; what is lost
      # is surviving a restart.
      notify(:not_durable)
    rescue CybrosAgent::Error
      # Transient: a throttle, a server failure, a store that was busy. The
      # lead time exists precisely so these can be tried again.
      notify(:deferred)
    end

    private

      def notify(event)
        @on_event&.call(event)
        event
      end
  end
end
