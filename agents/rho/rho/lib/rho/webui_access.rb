require "ipaddr"
require "openssl"
require "securerandom"

module Rho
  # WHO MAY OPEN THE WEBUI once rho is paired. Pairing is rho's bond with
  # Nexus and happens once; this is the gate in front of the page every time
  # a browser arrives. Three modes: `open` lets the page in by itself,
  # `password` asks for rho's own unlock password, `nexus` asks for a Nexus
  # sign-in. The setting's nil chooses by bind — open on loopback, where the
  # same person's processes already hold the operator bearer, nexus anywhere
  # another machine can reach. A Nexus sign-in is accepted in every mode; it
  # is what a page needs for Human-plane requests.
  #
  # The password lives only as a salted scrypt digest in a private file, with
  # a generation that every unlocked session carries: changing or clearing
  # the password ends the sessions unlocked under the old one.
  class WebuiAccess
    MODES = Config::WEBUI_ACCESS
    MIN_PASSWORD = 8
    MAX_PASSWORD = 1024
    # Guesses are bounded per process, not per address: rho has one owner
    # and no per-client state worth keeping.
    MAX_ATTEMPTS = 5
    ATTEMPT_WINDOW = 60
    SCRYPT = { "N" => 16_384, "r" => 8, "p" => 1, "length" => 32 }.freeze
    LOOPBACK = %w[127.0.0.1 localhost ::1].freeze

    Verdict = Data.define(:code, :message, :retry_after) do
      def initialize(code:, message:, retry_after: nil) = super
      def accepted? = code == :accepted
    end

    def initialize(home:, config:, bind:, clock: -> { Time.now })
      @home, @config, @bind, @clock = home, config, bind, clock
      @failures = []
      @lock = Mutex.new
    end

    # The mode in force: the setting, else the bind's own.
    def mode
      @config.webui_access || (loopback? ? "open" : "nexus")
    end

    def configured = @config.webui_access

    def password_set? = !document.nil? && document.key?("digest")

    # Monotonic across sets and clears, so a session unlocked under any
    # earlier password never comes back.
    def generation = document&.fetch("generation") || 0

    # What the public status says, and what the settings page shows.
    def describe
      { mode: mode, configured: configured, password_set: password_set? }
    end

    # A new password replaces the old one under a new generation; nil clears
    # it, also under a new generation, so no session stays unlocked by a
    # password that no longer exists.
    def set_password(password)
      next_generation = generation + 1
      if password.nil?
        file.write("generation" => next_generation)
        return false
      end
      text = password.to_s
      unless (MIN_PASSWORD..MAX_PASSWORD).cover?(text.bytesize)
        raise ConfigurationError, "The unlock password needs between #{MIN_PASSWORD} and #{MAX_PASSWORD} bytes"
      end

      salt = SecureRandom.random_bytes(16)
      file.write("algorithm" => "scrypt", **SCRYPT, "salt" => [salt].pack("m0"),
        "digest" => [derive(text, salt, SCRYPT)].pack("m0"), "generation" => next_generation)
      true
    end

    # One attempt to unlock: the mode decides whether a password is even the
    # question, and a run of wrong ones is held off for a window.
    def unlock(password)
      case mode
      when "open" then Verdict.new(code: :accepted, message: nil)
      when "nexus" then Verdict.new(code: :nexus_login_required, message: "This rho asks for a Nexus sign-in")
      when "password" then verify(password.to_s)
      else raise StateError, "unknown webui access mode #{mode.inspect}"
      end
    end

    private

      def verify(password)
        now = @clock.call
        @lock.synchronize do
          @failures.reject! { |at| at <= now - ATTEMPT_WINDOW }
          if @failures.length >= MAX_ATTEMPTS
            wait = (@failures.first + ATTEMPT_WINDOW - now).ceil
            return Verdict.new(code: :throttled, message: "Too many attempts; wait #{wait} seconds", retry_after: wait)
          end
        end
        stored = document
        unless password_set?
          return Verdict.new(code: :password_not_set, message: "No unlock password is set; sign in with Nexus to set one")
        end

        salt = stored.fetch("salt").unpack1("m0")
        expected = stored.fetch("digest").unpack1("m0")
        parameters = stored.slice("N", "r", "p", "length")
        if password.bytesize <= MAX_PASSWORD && OpenSSL.secure_compare(derive(password, salt, parameters), expected)
          Verdict.new(code: :accepted, message: nil)
        else
          @lock.synchronize { @failures << now }
          Verdict.new(code: :refused, message: "That is not the unlock password")
        end
      end

      def derive(password, salt, parameters)
        OpenSSL::KDF.scrypt(password, salt: salt, N: parameters.fetch("N"), r: parameters.fetch("r"),
          p: parameters.fetch("p"), length: parameters.fetch("length"))
      end

      def loopback?
        LOOPBACK.include?(@bind.to_s) || IPAddr.new(@bind.to_s).loopback?
      rescue IPAddr::InvalidAddressError
        false
      end

      def file = StateFile.new(@home.webui_password_path)

      def document = file.read
  end
end
