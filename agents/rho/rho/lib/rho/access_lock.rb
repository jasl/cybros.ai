require "openssl"

module Rho
  # The passphrase gate for remote control access. A non-loopback bind requires this gate
  # in addition to an explicit transport-security setting. A successful unlock releases
  # the per-boot bearer; ordinary control routes then require that bearer. The passphrase
  # does not encrypt traffic: TLS or a VPN belongs to the deployment in front of this
  # socket.
  #
  # WHAT IT ACTUALLY GUARDS is the bootstrap document — the one surface that
  # hands the per-boot bearer to whoever asks. Every other control route
  # already requires that bearer, so gating the bootstrap gates everything
  # reachable without one.
  # IT IS NOT TRANSPORT SECURITY, because a passphrase cannot encrypt traffic: the
  # requirement applies even under `--expect-external-encryption`, because a passphrase is
  # not encryption. TLS belongs to whatever fronts the socket — a reverse proxy or a VPN —
  # which the daemon cannot observe and therefore never claims.
  class AccessLock
    MIN_LENGTH = 8
    # Exponential, doubling per failure, and it bounds the WHOLE server
    # rather than one peer: the passphrase gates a bearer that grants shell,
    # and a per-peer bucket is a per-source-address bucket, which is exactly
    # what an attacker varies. One guess per window for everyone is the
    # posture; the operator who locked themselves out waits with them.
    MAX_DELAY_SECONDS = 300

    Attempt = Data.define(:accepted, :retry_after_seconds) do
      def accepted? = accepted
      def throttled? = !accepted && !retry_after_seconds.nil?
    end

    class << self
      # nil when no passphrase is configured — an unlocked daemon, which is
      # the only posture a loopback bind needs.
      def build(passphrase, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        return nil if passphrase.nil? || passphrase.empty?

        new(passphrase: passphrase, clock: clock)
      end

      # Refuse a trivially guessable passphrase loudly rather than pretending
      # it locks anything.
      def validate!(passphrase)
        return nil if passphrase.nil? || passphrase.empty?

        unless passphrase.is_a?(String) && passphrase.length >= MIN_LENGTH
          raise ConfigurationError,
            "access_passphrase must be at least #{MIN_LENGTH} characters"
        end

        passphrase
      end
    end

    def initialize(passphrase:, clock:)
      @passphrase = self.class.validate!(passphrase).dup.freeze
      @clock = clock
      @failures = 0
      @retry_at = nil
      @mutex = Mutex.new
    end

    # THE THROTTLE DECISION AND THE COMPARE ARE ONE CRITICAL SECTION. The
    # predecessor recorded why the hard way: its unlock read the request body
    # between the two, and reading a body awaits socket I/O. N concurrent
    # slowloris unlocks all cleared the gate before any of them armed the
    # next window, which admitted N guesses per window instead of one. This
    # method takes no I/O and holds a mutex, so the window means what it says.
    def attempt(candidate)
      @mutex.synchronize do
        now = @clock.call
        if @retry_at && now < @retry_at
          next Attempt.new(accepted: false, retry_after_seconds: (@retry_at - now).ceil)
        end

        if candidate.is_a?(String) && OpenSSL.secure_compare(@passphrase, candidate)
          @failures = 0
          @retry_at = nil
          next Attempt.new(accepted: true, retry_after_seconds: nil)
        end

        @failures += 1
        @retry_at = now + delay
        Attempt.new(accepted: false, retry_after_seconds: nil)
      end
    end

    private

      # Capped so a long-running daemon cannot lock its operator out for
      # hours over a typo, and floored at one doubling so the first miss
      # already costs something.
      def delay = [2**[@failures, 8].min, MAX_DELAY_SECONDS].min
  end
end
