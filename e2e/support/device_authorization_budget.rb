module E2E
  # Nexus rate-limits POST /oauth/device_authorization to 6 per minute per IP —
  # a product control this harness deliberately leaves untouched (the numbers
  # mirror `rate_limit` on nexus's device authorizations controller; a kernel
  # tightening shows up here as 429s, and this header is the pointer). Every
  # journey starts its ceremonies from one loopback address, so the SUITE is
  # the client the limit sees, and it must live inside the budget the way any
  # single machine would: consume before starting a ceremony, wait the window
  # out when the trailing minute is spent.
  #
  # The guarantee, stated exactly: a consume that returns cannot be refused,
  # PROVIDED the anchoring request reached Nexus within PAD seconds of its
  # grant. The server's fixed window anchors at the request's arrival, while
  # this ledger stamps the grant before the request starts — so a grant whose
  # request was slow to launch (a spawned CLI cold-booting its bundle is the
  # worst case here) holds its server-side slot LATER than this ledger thinks.
  # Both admission paths therefore keep every grant on the books for
  # WINDOW + PAD, conceding a little waiting when saturated to make admission
  # unconditional within the stated bound.
  #
  # Only a request that actually reaches Nexus consumes: a second click on a
  # pending ceremony is answered from the daemon's memory and costs nothing.
  module DeviceAuthorizationBudget
    LIMIT = 6
    WINDOW = 60
    # The grant-to-arrival latency this harness promises to absorb. A spawned
    # `bundle exec ruby exe/rho connect` measures ~0.3s warm and whole seconds
    # on a cold CI cache; in-process calls are microseconds.
    PAD = 15

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
