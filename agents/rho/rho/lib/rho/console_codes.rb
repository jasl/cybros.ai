require "openssl"
require "securerandom"

module Rho
  # HOW A BROWSER GETS THE BEARER. Minted by an already-authenticated caller
  # (`POST /console/code`, which `rho console` drives), redeemed once by the
  # page (`POST /console/session`). That ordering is the whole security
  # argument: a code exists only because somebody who already held the bearer
  # asked for one, so this is never a way to OBTAIN a credential — only to
  # move one you have into a page, which cannot read files.
  #
  # NOTHING IS PRINTED AT BOOT, deliberately. A code printed by `rho server`
  # would land in a process supervisor's merged stdout — tee'd to a
  # world-readable file, or into a group-readable journal — which is exactly
  # the read this mechanism exists to close, and the opposite of the
  # discipline `exe/rho` already states about the bearer.
  #
  # NO THROTTLE, DELIBERATELY — do not reach for AccessLock here. Its global
  # one-guess-per-window is calibrated for a human-chosen passphrase, whose
  # keyspace is searchable. A 256-bit code has no such keyspace, so a throttle
  # would buy nothing and sell the console's only availability: one wrong POST
  # every five minutes from any local process would keep the operator out
  # until a restart, and a restart TERMs every process group the runner owns.
  # Guessing is not the threat. Theft is, and TTL plus single use bounds it.
  #
  # AND DO NOT "FIX" RELOAD BY MAKING A CODE MULTI-USE AND NON-EXPIRING. That
  # is a second bearer with a shorter name: same blast radius, more code, no
  # gain. Reload is answered in the page, and a fresh code is one `rho
  # console` away.
  class ConsoleCodes
    # Long enough to paste into a browser on another machine over SSH, short
    # enough that a code sitting in scrollback, a shell history, a tmux buffer
    # or a screen share is inert before anyone reads it. Single-use and
    # short-lived are two properties; neither is redundant.
    TTL_SECONDS = 90
    # Two tabs and two people are normal. An unbounded map fed by an
    # authenticated caller is a slow leak; a cap of one would make a second
    # `rho console` silently break the first tab's pending link.
    MAX_OUTSTANDING = 8

    Entry = Data.define(:digest, :expires_at, :spent)

    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @clock = clock
      @entries = [].freeze
      @mutex = Mutex.new
    end

    def mint
      code = SecureRandom.urlsafe_base64(32)
      @mutex.synchronize do
        now = @clock.call
        entry = Entry.new(digest: self.class.digest(code), expires_at: now + TTL_SECONDS,
          spent: false)
        @entries = (sweep(@entries, now) + [entry]).last(MAX_OUTSTANDING).freeze
      end
      code
    end

    # COMPARE AND BURN ARE ONE CRITICAL SECTION CONTAINING NO IO. The caller
    # reads the request body FIRST and hands this a String — the mistake this
    # codebase has already paid for twice is a decision that straddles a
    # socket read, which is not one critical section however it looks.
    def redeem(candidate)
      return :unknown unless candidate.is_a?(String) && !candidate.empty?

      digest = self.class.digest(candidate)
      @mutex.synchronize do
        entries = sweep(@entries, @clock.call)
        index = entries.index { |entry| OpenSSL.secure_compare(entry.digest, digest) }
        @entries = entries.freeze
        next :unknown if index.nil?
        # SPENT IS KEPT UNTIL IT EXPIRES, which is the only reason a replay is
        # distinguishable from a link that merely went stale.
        next :spent if entries[index].spent

        @entries = entries.each_with_index
          .map { |entry, position| position == index ? entry.with(spent: true) : entry }
          .freeze
        :ok
      end
    end

    # Digests, not codes: nothing in this process holds a live credential in
    # plain form, and the fingerprint is what a log line may carry.
    def self.digest(code) = OpenSSL::Digest::SHA256.digest(code.to_s)
    def self.fingerprint(code) = OpenSSL::Digest::SHA256.hexdigest(code.to_s)[0, 12]

    private

      def sweep(entries, now) = entries.reject { |entry| entry.expires_at <= now }
  end
end
