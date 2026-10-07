require "test_helper"

# The single-instance primitive. It is a lifetime-held flock rather than a pid
# file because the kernel releases it on any death — including SIGKILL, a
# container stop, or a power cut — so there is nothing to reap afterwards and
# no pid to misidentify once the number is reused. RuboCop's server releases
# its startup flock as soon as its pid file lands and never re-checks inside
# it, which is exactly where its duplicate-daemon race lives; this one is
# never released early.
class LockTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-lock")
    @path = File.join(@root, "installation", "boot.lock")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_one_holder_at_a_time
    held = Rho::Lock.acquire(@path)

    assert_raises(Rho::Lock::AlreadyHeld) { Rho::Lock.acquire(@path) }
    held.release
    Rho::Lock.acquire(@path).release
  end

  # The lock lives in an open file, and Ruby releases a flock when it finalizes
  # the File. If the object holding it can be collected, the installation
  # quietly becomes claimable while the daemon that "holds" it is still
  # running — no error, nothing to observe. A few thousand allocations is
  # enough to trigger it, so the primitive must keep itself alive.
  def test_an_acquired_lock_survives_garbage_collection_without_being_kept
    Rho::Lock.acquire(@path)
    3.times { GC.start }
    500_000.times { +"churn" }
    3.times { GC.start }

    assert_raises(Rho::Lock::AlreadyHeld) { Rho::Lock.acquire(@path) }
  end

  def test_a_released_lock_is_not_kept_alive_forever
    Rho::Lock.acquire(@path).release
    3.times { GC.start }

    Rho::Lock.acquire(@path).release
  end

  def test_the_refusal_names_what_is_locked
    Rho::Lock.acquire(@path)

    error = assert_raises(Rho::Lock::AlreadyHeld) { Rho::Lock.acquire(@path) }
    assert_includes error.message, @path
  end

  def test_it_creates_its_directory_privately
    Rho::Lock.acquire(@path)

    assert_equal 0o700, File.stat(File.dirname(@path)).mode & 0o777
    assert_equal 0o600, File.stat(@path).mode & 0o777
  end

  # A narrowing umask must not leave a lock file this process can never open
  # again — that would make the installation permanently unbootable.
  def test_a_narrowing_umask_does_not_brick_the_lock
    previous = File.umask(0o277)
    Rho::Lock.acquire(@path).release

    Rho::Lock.acquire(@path).release
  ensure
    File.umask(previous) if previous
  end

  # The property no pid file has. A holder that dies without unwinding leaves
  # nothing behind: the next boot simply succeeds.
  def test_a_killed_holder_leaves_nothing_to_reap
    lib = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      $LOAD_PATH.unshift(#{lib.inspect})
      require "rho"
      Rho::Lock.acquire(#{@path.inspect})
      puts "held"
      $stdout.flush
      sleep 60
    RUBY

    reader, writer = IO.pipe
    pid = spawn(RbConfig.ruby, "-e", script, out: writer)
    writer.close
    assert_equal "held\n", reader.gets, "the child must own the lock before we test the takeover"
    assert_raises(Rho::Lock::AlreadyHeld) { Rho::Lock.acquire(@path) }

    Process.kill("KILL", pid)
    Process.waitpid(pid)

    Rho::Lock.acquire(@path).release
  ensure
    reader&.close
  end

  # rho takes exactly one lock — the home's boot lock — but the class is a
  # general one, and two distinct paths must stay independent: a second lock
  # anywhere must not be answered by the first one's holder.
  def test_two_locks_can_be_held_at_once
    boot = Rho::Lock.acquire(@path)
    identity = Rho::Lock.acquire(File.join(@root, "identity", "identity.lock"))

    assert_raises(Rho::Lock::AlreadyHeld) { Rho::Lock.acquire(@path) }
    boot.release
    identity.release
  end
end
