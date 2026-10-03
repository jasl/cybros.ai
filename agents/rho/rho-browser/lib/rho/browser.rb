require "rho/runner"
require_relative "browser/version"
require_relative "browser/driver"
require_relative "browser/session"
require_relative "browser/snapshot_text"
require_relative "browser/tools/snapshot"
require_relative "browser/tools/navigate"
require_relative "browser/tools/click"
require_relative "browser/tools/type"
require_relative "browser/tools/screenshot"
require_relative "browser/tools/evaluate"

module Rho
  # A BROWSER, AS AN EXTENSION. Six tools over Playwright, registered
  # through the same door the seven coding built-ins use — which is the
  # point: this is the plane's first consumer that is not the plane's own
  # author, and a plane whose only consumer is its author is untested.
  # WHAT IT IS NOT: a background task. The distinction is that a background task is
  # something a PERSON can see and operate — a dev server the model opened, listed,
  # killable. A browser is the extension's private, stateful internals: close it out from
  # under a running loop and every later call fails for a reason nobody can see. So it is
  # never listed or killable by a person. The session releases idle tabs and the idle
  # browser; shutdown releases everything.
  #
  # ONE BROWSER PER PROCESS, held here rather than on a tool. The registry
  # builds one tool instance per toolset and shares it across every worker
  # thread, so a tool keeps no mutable state (Registry#toolset says so in
  # its contract); and a toolset is REBUILT when the environment moves
  # (`rho env <dir>`), so anything hung off a tool would die on every
  # move. The extension object itself is memoized for the daemon's life —
  # which is exactly the lifetime a browser wants, because a browser is
  # not bound to a working directory.
  #
  # SIX, NOT TWENTY-FOUR. `@playwright/mcp` declares 24 tools in ~18.5 KB;
  # rho's entire coding surface is under 5 KB. Declarations are the front
  # of every cached prompt prefix, so the surface here is the smallest set
  # the references agree on: a snapshot that returns opaque refs as the
  # page-reading primitive, four verbs over those refs, and ONE honest
  # escape hatch (`browser_evaluate`) declared as the dangerous thing it
  # is, through which everything else — hover, drag, tabs, waiting — is
  # still reachable.
  module Browser
    NAME = "rho.browser".freeze

    TOOLS = [
      Tools::Snapshot, Tools::Navigate, Tools::Click,
      Tools::Type, Tools::Screenshot, Tools::Evaluate,
    ].freeze

    Closed = Class.new(Rho::Runner::Error)

    LOCK = Mutex.new

    # How long an unused tab or browser lives, in seconds. An operator on a small
    # machine may want it shorter; an invalid value is the default, never
    # an error at the first page.
    IDLE_ENV_KEY = "RHO_BROWSER_IDLE_SECONDS".freeze

    class << self
      # HOW A TEST SUPPLIES A FAKE BROWSER, and the only seam this module
      # exposes for it. Production never sets it: the default builds a
      # Playwright driver from the environment.
      attr_writer :driver_factory

      def driver_factory
        @driver_factory ||= -> { Driver.new }
      end

      # The one session this process owns, built on first use — so a
      # daemon with the extension loaded and no loop that ever touches a
      # page never spawns a browser at all.
      #
      # BUILT UNDER A LOCK, because `||=` is two operations and the first
      # two browser calls of a round arrive on two worker threads at
      # once. Without this, both construct a Session, one wins the
      # ivar, and the other's browser — already started by the thread
      # holding it — is orphaned: never closed, because `close!` only
      # knows the winner.
      #
      # AND NEVER AGAIN AFTER `close!`. The shutdown hook fires before the
      # worker pool drains, so a worker can dequeue a browser call while
      # the host is going away; a `||=` here would hand it a fresh Session
      # that launches a Chromium nothing will ever close.
      def session
        LOCK.synchronize do
          raise Closed, "the browser host is shutting down" if @closed

          @session ||= Session.new(driver: driver_factory.call, idle_after: idle_after, log: @log)
        end
      end

      def idle_after
        seconds = Float(ENV.fetch(IDLE_ENV_KEY, ""), exception: false)
        seconds&.positive? ? seconds : Session::IDLE_SECONDS
      end

      def close!
        current = LOCK.synchronize do
          @closed = true
          taken = @session
          @session = nil
          taken
        end
        current&.close
      end

      # For tests: forget everything — in ONE critical section, so a call
      # racing this cannot build a Session from the outgoing fake and
      # leave it for the next test.
      def reset!
        current = LOCK.synchronize do
          taken = @session
          @session = nil
          @driver_factory = nil
          @closed = false
          taken
        end
        current&.close
      end

      def register(api)
        # The host's logger, kept for the threads that have nobody to
        # answer: a reaper, a driver that dies idle.
        @log = api.log
        TOOLS.each { |klass| api.register_tool(klass) }
        # A runner rebuilt for a new working directory keeps the session;
        # shutdown closes it even when calls are still draining.
        api.on(:shutdown) { close! }
      end
    end
  end
end
