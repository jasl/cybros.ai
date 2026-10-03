require "test_helper"
require "tmpdir"
require "async"
require "pp"

# The one atomic state-file utility, and rho's implementation of the
# SDK's credential store port. It holds the only copy of a rotating refresh
# token, so crash-safe publication, private modes, and in-process exclusion are
# behavior rather than implementation detail. The daemon's lifetime Home lock
# owns the process boundary.
class StateFileTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cybros-state")
    @path = File.join(@root, "vault", "credentials.json")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def state_file(path = @path)
    Rho::StateFile.new(path)
  end

  def mode_of(path)
    File.stat(path).mode & 0o777
  end

  def test_a_document_round_trips
    file = state_file

    assert_equal({ "refresh_token" => "rt-x" }, file.write("refresh_token" => "rt-x"))
    assert_equal({ "refresh_token" => "rt-x" }, file.read)
    assert_equal({ "refresh_token" => "rt-x" }, state_file.read, "a second handle reads the same document")
  end

  def test_a_missing_document_reads_as_absent_rather_than_failing
    assert_nil state_file.read
  end

  # Corruption is not absence. For a credential store, reporting "no
  # credentials" would silently discard a live session and start a reconnect;
  # the operator is told the file is broken instead.
  def test_a_corrupt_document_is_a_typed_failure_not_an_empty_read
    file = state_file
    file.write("refresh_token" => "rt-x")
    File.write(@path, "{not json")

    error = assert_raises(Rho::StateError) { file.read }
    assert_match(/not valid JSON/, error.message)
  end

  def test_the_document_and_its_directory_are_private_from_the_first_byte
    state_file.write("refresh_token" => "rt-x")

    assert_equal 0o600, mode_of(@path)
    assert_equal 0o700, mode_of(File.dirname(@path))
  end

  # The window matters: a file created under the ambient umask and chmod'd
  # afterwards is world-readable for that instant, which is exactly when the
  # secret is already on disk. Under the most permissive umask there is, an
  # implementation that did not pass an explicit creation mode would leave a
  # 0666 document (and a 0777 directory) behind.
  def test_the_document_is_private_even_under_a_fully_permissive_umask
    previous = File.umask(0o000)
    state_file.write("refresh_token" => "rt-x")

    assert_equal 0o600, mode_of(@path)
    assert_equal 0o700, mode_of(File.dirname(@path))
  ensure
    File.umask(previous) if previous
  end

  def test_a_document_that_became_readable_by_others_is_refused_not_repaired
    file = state_file
    file.write("refresh_token" => "rt-x")
    File.chmod(0o644, @path)

    error = assert_raises(Rho::StateError) { file.read }
    assert_match(/private/, error.message)
    assert_equal 0o644, mode_of(@path), "a silent repair would hide the exposure that already happened"
  end

  # Atomic replacement naturally creates a new 0600 file. Check the existing
  # mode before replacement so a prior exposure remains visible instead of
  # being silently hidden by the next credential write.
  def test_a_document_that_became_readable_by_others_is_refused_on_write_too
    file = state_file
    file.write("refresh_token" => "rt-old")
    File.chmod(0o644, @path)

    error = assert_raises(Rho::StateError) { file.write("refresh_token" => "rt-new") }
    assert_match(/private/, error.message)
    assert_equal 0o644, mode_of(@path)
    assert_match(/rt-old/, File.read(@path), "the exposed token must not be rotated away before anyone is told")
  end

  # The property is "no group or other access", not "exactly 0600". A stricter
  # mode leaks to nobody, and `chmod -R 700 ~/.config/...` is an ordinary way
  # to reach one — refusing it would brick the store over nothing.
  def test_a_document_stricter_than_expected_is_still_readable
    file = state_file
    file.write("refresh_token" => "rt-x")
    File.chmod(0o400, @path)

    assert_equal({ "refresh_token" => "rt-x" }, file.read)
  end

  # umask can only *narrow* a creation mode, so under a narrowing umask the
  # files this class creates land stricter than 0600.
  def test_a_narrowing_umask_does_not_brick_the_store
    previous = File.umask(0o277)
    file = state_file
    file.write("refresh_token" => "rt-x")

    assert_equal({ "refresh_token" => "rt-x" }, file.read)
    assert_equal({ "refresh_token" => "rt-x" }, state_file.read, "a second handle must still read it")
    assert_equal({ "refresh_token" => "rt-y" }, state_file.write("refresh_token" => "rt-y"))
  ensure
    File.umask(previous) if previous
  end

  def test_a_directory_that_became_readable_by_others_is_refused
    FileUtils.mkdir_p(File.dirname(@path), mode: 0o755)

    error = assert_raises(Rho::StateError) { state_file.write("a" => 1) }
    assert_match(/private/, error.message)
  end

  def test_a_write_leaves_no_temporary_files_behind
    file = state_file
    file.write("a" => 1)
    file.write("a" => 2)

    assert_equal ["credentials.json"], Dir.children(File.dirname(@path)).sort
  end

  # A failed serialization must not leave a stray temp file holding a partial
  # secret, and must not damage the document that was already there.
  def test_a_failed_write_leaves_the_previous_document_intact
    file = state_file
    file.write("refresh_token" => "rt-good")

    # Infinity has no JSON representation, so serialization fails after the
    # document on disk is already the one we must not damage.
    assert_raises(JSON::GeneratorError) { file.write("bad" => Float::INFINITY) }

    assert_equal({ "refresh_token" => "rt-good" }, file.read)
    assert_equal ["credentials.json"], Dir.children(File.dirname(@path)).sort
  end

  def test_a_reader_never_observes_a_partially_written_document
    file = state_file
    file.write("refresh_token" => "rt-initial")
    big = { "refresh_token" => "rt-#{"x" * 400_000}" }
    stop = false

    reader = Thread.new do
      results = []
      results << state_file.read until stop
      results
    end
    10.times { file.write(big) ; file.write("refresh_token" => "rt-initial") }
    stop = true

    observations = reader.value
    refute_empty observations
    observations.each do |document|
      assert document.key?("refresh_token"), "a torn read produced #{document.inspect[0, 80]}"
    end
  end

  # `#write` has always refused a non-object. A hand-edited file holding one
  # used to pass straight through `#read` to callers that all index it like a
  # Hash, so one bad file surfaced as an unrelated error elsewhere.
  def test_a_document_that_is_not_an_object_is_refused_on_read_as_well_as_write
    ["[1,2]", '"just a string"', "42"].each do |raw|
      # The WRITE half hands `#write` a deliberately wrong type, and RBS's
      # runtime hook rejects it before the method can — so that refusal is
      # only observable off the conformance pass. The READ half below needs no
      # such call and runs on both.
      unless ENV["RBS_TEST_TARGET"]
        assert_raises(Rho::StateError) { state_file.write(JSON.parse(raw)) }
      end

      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      File.write(@path, raw)
      File.chmod(0o600, @path)

      error = assert_raises(Rho::StateError) { state_file.read }
      assert_match(/takes a JSON object/, error.message)
    end
  end

  # JSON object names are strings, so a document carrying both "k" and :k
  # serializes to a duplicate key and re-reads as the last one — while the Hash
  # handed back to the caller still answers with the first. Following
  # persist-before-use off that stale half means presenting a refresh token the
  # server has already spent, which reads as reuse and revokes the family.
  def test_symbol_keys_persist_and_return_one_value
    file = state_file
    persisted = file.write(refresh_token: "rt-new")

    assert_equal({ "refresh_token" => "rt-new" }, persisted)
    assert_equal persisted, file.read, "the returned document must be the one on disk"
    assert_equal 1, File.read(@path).scan(/"refresh_token"/).length, "a duplicate key hides the spent token"
  end

  def test_symbol_keys_are_canonicalized_at_every_depth
    file = state_file
    persisted = file.write(member: { refresh_token: "rt-new" })

    assert_equal({ "member" => { "refresh_token" => "rt-new" } }, persisted)
    assert_equal persisted, file.read
  end

  # Once the rename lands, the document IS on disk. A failure after that point
  # must not look like a failed write: a caller that retried a rotation would
  # present the token the server just consumed.
  def test_a_failure_after_the_document_is_published_says_so_rather_than_looking_like_a_failed_write
    unflushable = Class.new(Rho::StateFile) do
      private

        def fsync_directory
          raise Errno::EIO
        end
    end
    file = unflushable.new(@path)

    error = assert_raises(Rho::StateFile::PublishedError) { file.write("refresh_token" => "rt-new") }
    assert_match(/do not retry/, error.message)
    assert_equal({ "refresh_token" => "rt-new" }, state_file.read, "the document is published despite the failure")
    assert_kind_of Rho::StateError, error, "a caller rescuing the general failure must still catch it"
  end

  def test_with_lock_holds_across_a_caller_s_own_read_and_write
    file = state_file
    file.write("counter" => 0)

    file.with_lock do
      current = file.read.fetch("counter")
      file.write("counter" => current + 1)
    end

    assert_equal 1, file.read.fetch("counter")
  end

  # A different fiber on the same thread cannot take the lock the thread
  # already holds, and must not silently proceed without it either.
  # Exclusion inside one process has to be right in both worlds rho runs in.
  #
  # Without a scheduler there is no way for the holder to yield, so a second
  # fiber on the same thread cannot wait — and Ruby says so instead of letting
  # it through. Failing loudly is the point; silently bypassing the lock is the
  # outcome that would cost a refresh token.
  def test_a_second_fiber_without_a_scheduler_fails_fast_instead_of_bypassing_the_lock
    file = state_file
    file.write("a" => 1)
    outcome = nil

    file.with_lock do
      outcome = Fiber.new { (file.read rescue $!) }.resume
    end

    assert_kind_of ThreadError, outcome
    assert_match(/fiber/i, outcome.message)
  end

  # And under a reactor — where rho's control surface now runs — a second fiber
  # wanting the same file is ordinary, not an error: it suspends, the holder
  # finishes, it proceeds. The distinction is asserted rather than assumed.
  def test_a_second_fiber_under_a_scheduler_waits_rather_than_failing
    file = state_file
    file.write("counter" => 0)
    order = []

    Async do
      first = Async do
        file.with_lock do
          order << :first_entered
          # A suspension point inside the critical section: without one, the
          # first task could finish before the second ever starts, and the
          # test would pass without a wait ever happening.
          sleep 0.05
          file.write("counter" => file.read.fetch("counter") + 1)
          order << :first_left
        end
      end

      second = Async do
        sleep 0.01
        file.with_lock do
          order << :second_entered
          file.write("counter" => file.read.fetch("counter") + 1)
        end
      end

      [first, second].each(&:wait)
    end

    assert_equal %i[first_entered first_left second_entered], order,
      "the second fiber must wait for the first, not run inside its critical section"
    assert_equal 2, file.read.fetch("counter"), "a lost update means exclusion was bypassed"
  end

  def test_separate_handles_read_the_same_document
    first = state_file
    first.write("a" => 1)

    assert_equal({ "a" => 1 }, Rho::StateFile.new(@path).read)
    assert_equal({ "a" => 1 }, first.read)
  end

  # Separate StateFile objects for one path share the process-local lock.
  def test_two_stores_on_one_path_serialize_under_a_scheduler
    state_file.write("counter" => 0)
    order = []

    Async do
      writers = 2.times.map do |index|
        Async do
          sleep(index * 0.01)
          file = Rho::StateFile.new(@path)
          file.with_lock do
            order << index
            sleep 0.03
            file.write("counter" => file.read.fetch("counter") + 1)
          end
        end
      end
      writers.each(&:wait)
    end

    assert_equal [0, 1], order
    assert_equal 2, state_file.read.fetch("counter"), "a lost update means exclusion was bypassed"
  end

  # The create-once fence (link(2)): two competing owners can never both
  # publish, and the loser learns it lost rather than overwriting.
  def test_create_once_publishes_exactly_one_owner
    file = state_file

    assert file.create_once("owner" => "first")
    refute file.create_once("owner" => "second")
    assert_equal({ "owner" => "first" }, file.read)
    assert_equal 0o600, mode_of(@path)
  end

  def test_create_once_leaves_no_temporary_file_when_it_loses
    file = state_file
    file.create_once("owner" => "first")
    file.create_once("owner" => "second")

    assert_equal ["credentials.json"], Dir.children(File.dirname(@path)).sort
  end

  def test_delete_removes_the_document_and_is_idempotent
    file = state_file
    file.write("a" => 1)

    assert_nil file.delete
    assert_nil file.read
    assert_nil file.delete
  end

  def test_no_diagnostic_renders_the_document
    file = state_file
    file.write("refresh_token" => "rt-cybros-api-v1-secret.value")

    [file.inspect, file.to_s, PP.pp(file, +"")].each do |diagnostic|
      refute_includes diagnostic, "secret.value"
    end
  end

  def test_a_corrupt_document_error_never_renders_its_contents
    file = state_file
    file.write("refresh_token" => "rt-x")
    File.write(@path, "sk-cybros-api-v1-leaked.secret {")

    error = assert_raises(Rho::StateError) { file.read }
    refute_includes error.message, "leaked.secret"
  end
end
