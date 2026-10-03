require "monitor"

module E2E
  # Nexus rate-limits the public HTML login (POST /session) to 10 per
  # 3 minutes per IP — a product control this harness deliberately leaves
  # untouched (the numbers mirror `rate_limit` on nexus's sessions
  # controller). Every journey and every provisioning ceremony signs in from
  # one loopback address, so the SUITE is the client the limit sees and must
  # live inside the budget the way any single machine would: consume before
  # submitting a login, wait the window out when the trailing three minutes
  # are spent.
  #
  # The accounting mirrors DeviceAuthorizationBudget: a grant is stamped
  # before the form submits, the server's fixed window anchors at arrival,
  # and PAD absorbs the grant-to-arrival latency (form fill plus browser
  # round-trip), so an admitted consume cannot be refused within the stated
  # bound. Only submissions that reach POST /session consume; the first-boot
  # POST /setup and the API session login live under their own counters.
  module SessionSignInBudget
    LIMIT = 10
    WINDOW = 180
    PAD = 10

    @starts = []
    @monitor = Monitor.new
    @slept = 0.0

    # Seconds this process spent waiting the window out — printed at the end
    # of a run so a ledger that binds is measured, not guessed.
    def self.slept_seconds = @slept

    def self.consume
      @monitor.synchronize do
        loop do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @starts.reject! { |at| now - at > WINDOW + PAD }
          if @starts.length < LIMIT
            @starts << now
            return
          end

          wait = @starts.first + WINDOW + PAD - now
          @slept += wait
          sleep(wait)
        end
      end
    end
  end
end
