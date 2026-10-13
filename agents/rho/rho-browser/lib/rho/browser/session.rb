require "monitor"
require "timeout"

module Rho
  module Browser
    # A browser call that outlived its ceiling. A subclass of the runner's
    # error so a tool reports it like any other failure; the message names
    # what happened and what to do, because the model reads it.
    class CallTimedOut < Rho::Runner::Error; end

    # THE SIGNAL A CEILING RAISES INSIDE ITS BLOCK. Not a StandardError, so
    # no `rescue => e` between here and the block can swallow it; and not
    # `Timeout::Error`, so a tool's own inner timeout is never mistaken
    # for the session's and never restarts a healthy driver.
    class Deadline < Exception; end # rubocop:disable Lint/InheritException

    # THE SUPERVISOR: one browser, a tab per loop, a clock on everything.
    #
    # A TAB PER LOOP, ONE SHARED CONTEXT. Two loops on one daemon — two
    # `rho do`s on a home server — must not take turns on one tab where
    # the second's navigation invalidates the first's refs. Each loop gets
    # its own page, keyed by the loop id the execution context carries;
    # calls for DIFFERENT loops run concurrently, calls for the SAME loop
    # serialize (a model that emits two browser calls in one round gets
    # them one at a time, on one tab, in order). The context is shared on
    # purpose: a person who logged in once is logged in for every loop,
    # which every reference does and per-loop contexts would forbid.
    #
    # TWO LOCKS, ONE RULE. The registry guards the map and the driver's
    # start and stop; each tab has a lock for its calls. THE REGISTRY IS
    # THE ONLY LOCK A THREAD EVER WAITS ON. A tab lock is only ever
    # try-locked — by a caller under the registry, by the reaper under
    # the registry — and a thread holding a tab lock may take the
    # registry, because nothing can be waiting on the tab it holds. That
    # is the whole deadlock argument, and it is checkable by inspection.
    #
    # A GENERATION, SO A STALE VERDICT ACTS ON NOTHING. Every driver stop
    # bumps it; every tab records the generation it was born under; a
    # recovery that decides "the driver is dead" stops the driver only if
    # its tab's generation is still current — otherwise the driver it
    # failed on is already gone and a successor is running, and stopping
    # THAT would be one loop's failure restarting every other loop's
    # browser, generation after generation.
    #
    # TWO VERDICTS, KEPT APART, AND NEITHER ASKS THE WEDGED PAGE. A dead
    # process, a browser the driver has lost, or a tab that cannot even be
    # CLOSED on a clock is the DRIVER's failure — stop it, every tab goes
    # with it. A timed-out call on a live driver is THIS TAB's failure:
    # close it (a close is served by the browser process, not by the
    # page's own renderer — which is exactly what a `title` probe would
    # have asked, and a busy renderer would have answered for the wrong
    # verdict) and the other loops never notice.
    #
    # THE CLOCK IS ON THE WHOLE CRITICAL SECTION: waiting, starting,
    # calling, stopping. The session's reaper closes unused tabs even
    # while other loops keep browsing; a wholly idle browser is stopped
    # in one operation. Both use the same idle window, and neither
    # interrupts a call in flight or decides that a loop has ended.
    class Session
      CLOSE_WAIT_SECONDS = 5.0
      CALL_DEADLINE_SECONDS = 60.0
      START_DEADLINE_SECONDS = 90.0
      STOP_DEADLINE_SECONDS = 15.0
      # How long a caller may wait for the REGISTRY (another loop's start
      # or stop): start + stop with margin.
      REGISTRY_WAIT_SECONDS = 120.0
      # How long a caller may wait for its OWN loop's tab: an earlier
      # call or an idle close holds it, bounded by the call ceiling
      # plus recovery or the shorter page-close deadline.
      TAB_WAIT_SECONDS = CALL_DEADLINE_SECONDS + 20.0
      PAGE_CLOSE_SECONDS = 3.0
      POLL_SECONDS = 0.02
      IDLE_SECONDS = 600.0
      REAP_TICK_SECONDS = 15.0
      DEFAULT_OWNER = :default

      Tab = Struct.new(:page, :lock, :generation, :last_used_at, :fresh)

      # `clock:` is the monotonic second every ceiling and the idle window
      # are measured on (the daemon's `clock:` convention): a test advances
      # it instead of waiting real time.
      def initialize(driver:, log: nil, close_wait: CLOSE_WAIT_SECONDS,
                     call_deadline: CALL_DEADLINE_SECONDS,
                     start_deadline: START_DEADLINE_SECONDS,
                     stop_deadline: STOP_DEADLINE_SECONDS,
                     lock_wait: REGISTRY_WAIT_SECONDS,
                     tab_wait: TAB_WAIT_SECONDS,
                     idle_after: IDLE_SECONDS,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @driver = driver
        @log = log
        @clock = clock
        @close_wait = close_wait
        @call_deadline = call_deadline
        @start_deadline = start_deadline
        @stop_deadline = stop_deadline
        @registry_wait = lock_wait
        @tab_wait = tab_wait
        @idle_after = idle_after
        @registry = Mutex.new
        @tabs = {}
        @generation = 0
        @closed = false
        @last_used_at = nil
        @reaper = nil
        @wake = Queue.new
      end

      def started? = @driver.started?
      def reaping? = !!@reaper&.alive?
      def tab_count = @registry.synchronize { @tabs.size }

      # Yields the owner's page and whether it is new. The notice lives
      # with the tab, so retired owners leave no bookkeeping behind.
      # A returning loop must hear that its earlier refs no longer apply.
      def with_page(owner = DEFAULT_OWNER)
        context = Rho::Runner::ExecutionContext.current
        context&.raise_if_cancelled!
        tab = acquire_tab(owner, context)
        fresh = tab.fresh
        tab.fresh = false
        begin
          begin
            bounded(@call_deadline) { yield tab.page, fresh }
          rescue Deadline
            recover_after_timeout(owner, tab, context)
          rescue StandardError
            recover_after_error(owner, tab, context)
            raise
          end
        rescue Rho::Runner::ExecutionContext::Cancelled
          # A cancelled call delivered nothing — whether it was cancelled in
          # the yield or inside its own recovery's wait for the registry —
          # so the notice it consumed is owed to the owner's next call. The
          # outer rescue is what covers the recovery: an exception raised
          # inside a rescue clause is not caught by its siblings.
          tab.fresh = true if fresh
          raise
        ensure
          @last_used_at = tab.last_used_at = monotonic_now
          tab.lock.unlock
        end
      end

      # IDEMPOTENT, AND BOUNDED END TO END. The registry is waited for on
      # a clock; the driver is stopped on a clock, with or without it —
      # the driver's own stop takes every tab, so nothing is closed one
      # by one on the way out.
      def close
        @closed = true
        @wake << :closing
        acquired = wait_for(@registry, @close_wait)
        stop_driver!("closed")
      ensure
        @registry.unlock if acquired && @registry.owned?
        @reaper&.join(1)
      end

      private

        # LOOKUP-OR-CREATE AND THE TAB'S TRY-LOCK IN ONE REGISTRY SECTION.
        # A busy tab means an earlier call or an idle close: release
        # everything, wait a beat (cancellable), and look up again — so a
        # tab dropped in the meantime is not the one this call runs on.
        def acquire_tab(owner, context)
          deadline = monotonic_now + @tab_wait
          loop do
            context&.raise_if_cancelled!
            wait_for_registry(context)
            begin
              raise Closed, "the browser has been closed" if @closed

              context&.raise_if_cancelled!
              ensure_driver
              tab = current_tab(owner)
              if tab.lock.try_lock
                @last_used_at = tab.last_used_at = monotonic_now
                return tab
              end
            ensure
              @registry.unlock
            end
            if monotonic_now > deadline
              raise CallTimedOut,
                "an earlier browser call from this task is still running after " \
                "#{@tab_wait.round}s; browser calls run one at a time — make one per round"
            end
            sleep POLL_SECONDS
          end
        end

        # Called with the registry held. A page that closed on its own, or
        # a tab from a driver that is gone, is retired here and replaced —
        # UNLESS somebody holds it: a page can close under a call in
        # flight, and that call's own recovery is the one that drops it.
        # Handing the held tab back makes the caller's try-lock fail and
        # wait, which is the serialization the same loop is owed anyway.
        def current_tab(owner)
          tab = @tabs[owner]
          if tab && !tab.lock.locked? && (tab.generation != @generation || page_closed?(tab.page))
            @tabs.delete(owner)
            tab = nil
          end
          tab || create_tab(owner)
        end

        # The one driver round trip that stays under the registry: a new
        # page. Bounded like a start, and ANY failure here is the driver's
        # — a context that cannot open a page has lost its browser (the
        # OOM killer takes Chromium, not node), and the process being
        # alive says nothing about that.
        def create_tab(owner)
          page = bounded(@start_deadline) { @driver.new_page }
          @tabs[owner] = Tab.new(page, Mutex.new, @generation, monotonic_now, true)
        rescue Deadline
          stop_driver!("opening a tab exceeded #{@start_deadline}s")
          raise CallTimedOut,
            "opening a browser tab exceeded #{@start_deadline}s; the browser was restarted — " \
            "take a new browser_snapshot before acting"
        rescue StandardError => error
          stop_driver!("opening a tab failed: #{error.class.name}")
          raise CallTimedOut,
            "the browser could not open a tab (#{describe_failure(error)}); it was restarted — " \
            "take a new browser_snapshot before acting"
        end

        # The gem answers a call on a cleaned-up connection with a bare
        # NoMethodError on nil; the model does not need to read that. Any
        # other error is quoted, because the driver's own words are the
        # useful ones.
        def describe_failure(error)
          case error
          when NoMethodError then "the browser connection was already closed"
          else error.message
          end
        end

        # Called with the registry held.
        def ensure_driver
          stop_driver!("driver died") if @driver.started? && !driver_alive?
          return if @driver.started?

          bounded(@start_deadline) { @driver.start }
          @last_used_at = monotonic_now
          start_reaper
        rescue Deadline
          stop_driver!("starting the browser exceeded #{@start_deadline}s")
          raise CallTimedOut,
            "starting the browser exceeded #{@start_deadline}s; it will be retried on the " \
            "next call"
        rescue StandardError
          stop_driver!("starting the browser failed")
          raise
        end

        def driver_alive?
          @driver.alive?
        end

        # THE TWO VERDICTS. Holding the tab lock and NOT the registry.
        # A dead driver is restarted (generation-checked); a live one loses
        # only this tab — and if even closing the tab does not return on a
        # clock, drop_tab escalates to the driver verdict itself.
        def recover_after_timeout(owner, tab, context)
          if driver_alive?
            drop_tab(owner, tab, context, "call exceeded #{@call_deadline}s")
            raise CallTimedOut,
              "the browser call exceeded #{@call_deadline}s; this loop's tab was reset — take a " \
              "new browser_snapshot before acting"
          end

          restart_driver_if_current(tab.generation, context, "the browser call exceeded #{@call_deadline}s and the driver was dead")
          raise CallTimedOut,
            "the browser call exceeded #{@call_deadline}s and the browser was dead; it was " \
            "restarted — take a new browser_snapshot before acting"
        end

        def recover_after_error(owner, tab, context)
          if !driver_alive?
            restart_driver_if_current(tab.generation, context, "driver died")
          elsif page_closed?(tab.page)
            drop_tab(owner, tab, context, "page closed")
          end
        end

        # Holding the tab lock. The page is closed outside the registry
        # (a driver round trip must not stall every other loop), then the
        # entry is removed only if it is still THIS tab. The next call
        # opens a fresh tab and delivers its notice.
        def drop_tab(owner, tab, context, reason)
          @log&.info("browser_tab_dropped", owner: owner.to_s, reason: reason)
          # Capture descendants before closing their opener: Playwright
          # returns nil from Page#opener once that page has closed.
          roots = { tab.page => true }
          popups = @driver.open_pages.select { |page| !page.equal?(tab.page) && owned_page?(page, roots) }
          closed = close_pages([tab.page, *popups])
          with_registry(context) do
            @tabs.delete(owner) if @tabs[owner].equal?(tab)
          end
          # A tab that cannot even be closed on a clock is the driver's
          # failure after all.
          restart_driver_if_current(tab.generation, context, "closing a tab exceeded #{PAGE_CLOSE_SECONDS}s") unless closed
        end

        def owned_page?(page, roots)
          while page
            return true if roots.key?(page)

            page = page.opener
          end
          false
        end

        def close_pages(pages)
          Timeout.timeout(PAGE_CLOSE_SECONDS, Deadline) do
            pages.each do |page|
              page.close
            rescue StandardError
              # A page already gone must not prevent sibling cleanup.
              nil
            end
          end
          true
        rescue Deadline
          false
        end

        # GENERATION-CHECKED. Takes the registry (allowed: nothing waits on
        # the tab this thread holds) and stops the driver only if the tab
        # that failed was born under the driver that is running now.
        def restart_driver_if_current(generation, context, reason)
          with_registry(context) do
            stop_driver!(reason) if generation == @generation && @driver.started?
          end
        end

        # A RECOVERY WAITS FOR THE REGISTRY ON THE SAME TERMS AS A CALL:
        # polling, cancellable, with a ceiling. A recovery that cannot get
        # it in that time is behind another loop's restart, which makes
        # its own verdict moot; it logs and lets go.
        def with_registry(context)
          wait_for_registry(context)
          begin
            yield
          ensure
            @registry.unlock
          end
        rescue CallTimedOut => error
          @log&.warn("browser_recovery_skipped", detail: error.message)
          nil
        end

        # Called with the registry held. Every tab goes, every owner is
        # told, the generation moves, the driver is stopped on a clock.
        def stop_driver!(reason)
          @generation += 1
          @tabs.clear
          @log&.info("browser_driver_stopped", reason: reason)
          Timeout.timeout(@stop_deadline, Deadline) { @driver.stop }
        rescue Deadline, StandardError => error
          @log&.warn("browser_stop_failed", reason: reason, error_class: error.class.name)
        end

        def page_closed?(page)
          page.closed?
        rescue StandardError
          true
        end

        def bounded(seconds)
          Timeout.timeout(seconds, Deadline) { yield }
        end

        # Polling acquisition of the registry: cancellable, with a ceiling.
        def wait_for_registry(context)
          deadline = monotonic_now + @registry_wait
          until @registry.try_lock
            context&.raise_if_cancelled!
            if monotonic_now > deadline
              raise CallTimedOut,
                "the browser was busy starting or stopping for another task for more than " \
                "#{@registry_wait.round}s; try again"
            end
            sleep POLL_SECONDS
          end
        end

        def wait_for(mutex, seconds)
          deadline = monotonic_now + seconds
          until mutex.try_lock
            return false if monotonic_now > deadline

            sleep POLL_SECONDS
          end
          true
        end

        # One reaper for the driver. Idle tabs release their renderers
        # while busy tabs keep the shared context; a wholly idle browser
        # releases everything. Registry acquisition never blocks a call.
        def start_reaper
          return if @reaper&.alive?

          @reaper = Thread.new { reap_loop }
          @reaper.name = "rho-browser-reaper"
        end

        def reap_loop
          loop do
            @wake.pop(timeout: reap_tick)
            return if @closed
            return if look_for_idle == :gone
          end
        rescue StandardError => error
          @log&.warn("browser_reaper_failed", error_class: error.class.name)
        end

        def look_for_idle
          return :running unless @registry.try_lock

          begin
            return retire unless @driver.started?

            now = monotonic_now
            idle = now - @last_used_at
            if idle >= @idle_after && @tabs.values.none? { |tab| tab.lock.locked? }
              stop_driver!("idle for #{idle.round}s")
              return retire
            end

            candidates = @tabs.select { |_owner, tab| now - tab.last_used_at >= @idle_after }
          ensure
            @registry.unlock
          end
          candidates.each { |owner, tab| reap_tab(owner, tab) }
          reap_orphans
          :running
        end

        # A page can close itself, or finish opening a popup while being
        # retired. The context owns the page list; only the current main
        # pages and their opener chains have an owner. Taking this snapshot
        # under the registry excludes a main page still being registered.
        def reap_orphans
          return unless @registry.try_lock

          begin
            generation = @generation
            roots = @tabs.values.to_h { |tab| [tab.page, true] }
            pages = @driver.open_pages.reject { |page| owned_page?(page, roots) }
          ensure
            @registry.unlock
          end
          return if pages.empty?

          unless close_pages(pages)
            restart_driver_if_current(generation, nil, "closing orphaned pages exceeded #{PAGE_CLOSE_SECONDS}s")
          end
        end

        # Recheck after the snapshot: a caller may have used or replaced
        # the tab meanwhile. Closing holds only that tab's lock, never
        # the registry, so another loop can keep using its own page.
        def reap_tab(owner, tab)
          return unless @registry.try_lock

          begin
            held = @tabs[owner].equal?(tab) &&
              monotonic_now - tab.last_used_at >= @idle_after && tab.lock.try_lock
          ensure
            @registry.unlock
          end
          return unless held

          begin
            drop_tab(owner, tab, nil, "idle for #{(monotonic_now - tab.last_used_at).round}s")
          ensure
            tab.lock.unlock
          end
        end

        def retire
          @reaper = nil if @reaper == Thread.current
          :gone
        end

        def reap_tick
          [[@idle_after / 4.0, REAP_TICK_SECONDS].min, 0.01].max
        end

        def monotonic_now = @clock.call
    end
  end
end
