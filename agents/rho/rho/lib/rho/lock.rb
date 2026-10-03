require "fileutils"

module Rho
  # A lock held for the life of the process.
  #
  # It is an `flock` rather than a pid file because the kernel releases it on
  # any death — SIGKILL, a container stop, a power cut — so there is no stale
  # record to reap, no window between checking and claiming, and no pid to
  # misidentify once the number is reused. The oracles agree on where the
  # correctness lives: RuboCop's server takes a startup flock and rackup relies
  # on an `O_EXCL` create, while both use their pid file only for the operator's
  # message. Rho keeps the kernel primitive and gives the pid no authority at
  # all (it lives in the announcement, for discovery).
  #
  # It is never released early. RuboCop drops its startup lock as soon as the
  # daemon's pid file lands and never re-checks inside it, which is precisely
  # where its duplicate-daemon race lives.
  #
  # There is exactly one of these per process: the home's boot lock. An
  # identity-scoped second lock was tried and removed — an identity root lives
  # inside the home, so it excluded nothing the boot lock does not, while
  # leaking on every exit that did not adopt a connection. Reintroducing one
  # would bring back a lock order to get wrong; prefer widening this one.
  class Lock
    class AlreadyHeld < Error; end

    PRIVATE_DIRECTORY_MODE = 0o700
    PRIVATE_FILE_MODE = 0o600

    # A lock lives as long as the process, so the object owning its open file
    # has to as well. Ruby closes a File when it finalizes one, and closing
    # releases the flock — so a lock that merely went out of scope would
    # silently unclaim the home while the daemon that "holds" it keeps
    # running, with no error and nothing to observe. Holding every acquired
    # lock here makes the stated lifetime the real one instead of a duty
    # quietly delegated to every caller.
    HELD = []
    HELD_MUTEX = Mutex.new
    private_constant :HELD, :HELD_MUTEX

    # Claim it, or fail immediately. Never blocks: a caller waiting on this
    # would be waiting for another daemon to exit, which is not a thing that
    # is about to happen.
    def self.acquire(path)
      path = File.expand_path(path)
      FileUtils.mkdir_p(File.dirname(path), mode: PRIVATE_DIRECTORY_MODE)
      # Read-only: the lock carries no content, and asking for write access
      # would let a narrowing umask leave behind a file this process can never
      # open again — a home that can never boot.
      file = File.open(path, File::RDONLY | File::CREAT, PRIVATE_FILE_MODE)
      unless file.flock(File::LOCK_EX | File::LOCK_NB)
        file.close
        raise AlreadyHeld, "#{path} is held by another process"
      end

      lock = new(path, file)
      HELD_MUTEX.synchronize { HELD << lock }
      lock
    end

    def initialize(path, file)
      @path = path
      @file = file
    end

    def held? = !@file.closed?

    # For an orderly shutdown and for tests. A crash needs no counterpart:
    # that is the whole point of holding it in the kernel.
    def release
      HELD_MUTEX.synchronize { HELD.delete(self) }
      return if @file.closed?

      @file.flock(File::LOCK_UN)
      @file.close
      nil
    end

    def inspect = "#<Rho::Lock path=#{@path.inspect} held=#{held?}>"
    alias_method :to_s, :inspect
  end
end
