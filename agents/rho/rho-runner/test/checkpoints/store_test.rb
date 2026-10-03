require "test_helper"
require "json"
require "digest"

# THE SHADOW STORE: a bare git directory under the home's
# work root, one per root, holding whole-tree captures as parentless
# commits under `refs/checkpoints/<loop>` with the record as the message.
# Every case runs a REAL git against a throwaway root; the timeout and the
# git-failure arms run a stubbed git (M-mf6: the timeout is a unit case,
# never a journey estimate).
class CheckpointsStoreTest < Minitest::Test
  include RunnerTest::Helpers

  Store = Rho::Runner::Checkpoints::Store
  Record = Rho::Runner::Checkpoints::Record
  Skip = Rho::Runner::Checkpoints::Skip
  Restored = Rho::Runner::Checkpoints::Restored
  Refusal = Rho::Runner::Checkpoints::Refusal

  # The log duck: every event and its fields, for the pins on what a
  # capture and a restore say.
  class Log
    attr_reader :events

    def initialize = @events = []

    %i[debug info warn error].each do |level|
      define_method(level) { |event, **fields| @events << [event.to_s, fields] }
    end

    def named(event) = @events.select { |name, _| name == event }.map(&:last)
  end

  def setup
    @tmp = File.realpath(Dir.mktmpdir("rho-checkpoints"))
    @root = File.join(@tmp, "root")
    @dir = File.join(@tmp, "work", "checkpoints")
    FileUtils.mkdir_p(@root)
    @log = Log.new
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def open_store(root: @root, **options)
    Store.open(dir: @dir, root: root, log: @log, **options)
  end

  def write(path, content, root: @root)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.binwrite(full, content)
  end

  # EVERY file under the root, path => bytes (M-mf5: "present" is never
  # the pin; the bytes are).
  def snapshot(root = @root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }.to_h do |file|
      [file.delete_prefix("#{root}/"), File.binread(file)]
    end
  end

  # A read of the store through git itself, the user's config hidden.
  def store_git(store, *args, stdin: nil)
    env = { "GIT_DIR" => store.path, "GIT_WORK_TREE" => store.root, "GIT_CONFIG_GLOBAL" => File::NULL,
            "GIT_CONFIG_NOSYSTEM" => "1" }
    IO.popen(env, ["git", *args], "r+", err: File::NULL) do |io|
      io.write(stdin) if stdin
      io.close_write
      io.read
    end
  end

  def tree_paths(store, tree) = store_git(store, "ls-tree", "-r", "--name-only", tree).lines(chomp: true)

  # Every loose object's sha, off the store's object directory itself.
  def loose_objects(store)
    Dir.glob(File.join(store.path, "objects", "??", "*")).map { |f| f.split("/").last(2).join }.sort
  end

  # A checkout with one commit, made with a neutral git.
  def make_checkout(root, files)
    FileUtils.mkdir_p(root)
    files.each { |path, content| write(path, content, root: root) }
    env = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1",
            "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@x", "GIT_COMMITTER_NAME" => "t",
            "GIT_COMMITTER_EMAIL" => "t@x" }
    [%w[init -q], %w[add --all], %w[commit -qm c]].each do |args|
      assert system(env, "git", "-C", root, *args, out: File::NULL, err: File::NULL), "git #{args.first} in #{root}"
    end
    IO.popen(env, ["git", "-C", root, "rev-parse", "HEAD^{tree}"], &:read).strip
  end

  # ---- ignored ----

  # `Store#ignored` names the paths of a call the tree cannot hold: the
  # project's `.gitignore` and `info/exclude`, the protected roots and the
  # spill directory under the root, the store itself — by pattern, so a
  # file that does not exist yet is named before it lands; a tracked path
  # is never ignored; a timeout or a git failure answers `[]` (a mark, never a gate).
  def test_ignored_names_the_excluded_targets_by_pattern_and_never_a_tracked_path
    write(".gitignore", ".env\nlog/\n")
    write("lib/a.rb", "a")
    write(".env", "KEY=1")
    protected_root = File.join(@root, "vendor", "rho")
    FileUtils.mkdir_p(protected_root)
    store = open_store(protected_roots: [protected_root], excluded: [File.join(@root, "artifacts")])

    assert_equal [".env", "log/x.log", "vendor/rho/lib/rho.rb", "artifacts/spill.txt"],
      store.ignored([".env", "log/x.log", "vendor/rho/lib/rho.rb", "artifacts/spill.txt", "lib/a.rb", "new.rb"])
    assert_equal [], store.ignored(["lib/a.rb"])
    assert_equal [], store.ignored([])
    assert_equal [".env"], store.ignored([".env", ".env"]), "one name per path"

    checkout = File.join(@tmp, "checkout")
    make_checkout(checkout, "tracked.log" => "kept")
    write(".gitignore", "*.log\n", root: checkout)
    seeded = open_store(root: checkout)
    assert_equal ["other.log"], seeded.ignored(["other.log", "tracked.log"]),
      "a tracked path is not subject to the excludes; an untracked one is"
  end

  def test_ignored_answers_nothing_on_a_git_failure
    store = open_store(git: stub_git("exit 128"), capture_timeout_seconds: 5)

    assert_equal [], store.ignored([".env"])
  end

  # ---- open ----

  def test_open_initialises_a_bare_store_under_the_dir_keyed_by_the_roots_digest_and_is_idempotent
    write("a.txt", "a")
    store = open_store

    assert_equal Digest::SHA256.hexdigest(@root)[0, 16], store.id
    assert_equal File.join(@dir, store.id), store.path
    assert_equal @root, store.root
    assert_equal "true", store_git(store, "config", "core.bare").strip
    Store::CONFIG.each { |key, value| assert_equal value, store_git(store, "config", key).strip, key }
    assert File.directory?(File.join(store.path, "refs", "heads"))

    first = store.capture(loop: "loop-1")
    FileUtils.rm_rf(File.join(store.path, "refs", "heads")) # what a full pack removes (hermes's failure)
    again = open_store
    assert_equal store.id, again.id
    assert File.directory?(File.join(store.path, "refs", "heads")), "re-init recreates refs/heads"
    assert_equal first.hash, again.records(loop: "loop-1").first.hash, "the records survive a reopen"
    assert File.file?(File.join(store.path, "index")), "the index is kept across opens"
  end

  def test_open_refuses_a_root_at_or_under_a_protected_root_and_a_missing_root
    vault = File.join(@root, "vault")
    FileUtils.mkdir_p(File.join(vault, "deep"))
    assert_raises(ArgumentError) { open_store(root: vault, protected_roots: [vault]) }
    assert_raises(ArgumentError) { open_store(root: File.join(vault, "deep"), protected_roots: [vault]) }
    assert_raises(Errno::ENOENT) { open_store(root: File.join(@root, "nope")) }
    open_store(protected_roots: [vault]) # a protected root INSIDE the root is fine
  end

  # ---- capture ----

  def test_capture_takes_the_whole_tree_records_it_under_the_loops_ref_and_answers_the_key
    write("README.md", "readme")
    write("lib/a.rb", "one")
    store = open_store

    record = store.capture(loop: "al-1", outside: ["/elsewhere/x"], ignored: [".env"])

    assert_kind_of Record, record
    refute_predicate record, :skip?
    assert_equal %w[README.md lib/a.rb], tree_paths(store, record.hash)
    assert_equal "tree", store_git(store, "cat-file", "-t", record.hash).strip
    assert_equal 2, record.files
    assert_equal "al-1", record.loop
    assert_equal store.id, record.store
    assert_equal @root, record.root
    assert_equal({ "hash" => record.hash, "store" => store.id, "outside" => ["/elsewhere/x"], "ignored" => [".env"] },
      record.key)
    assert_equal({ "hash" => record.hash, "store" => store.id },
      store.capture(loop: "al-2").key, "outside and ignored are present-only")
    # The record IS the ref's object: one parentless commit, the message the JSON.
    commit = store_git(store, "rev-parse", "refs/checkpoints/al-1").strip
    body = store_git(store, "cat-file", "-p", commit)
    refute_match(/^parent /, body)
    assert_match(/^tree #{record.hash}$/, body)
    assert_equal record.to_row.except("present"), JSON.parse(body.split("\n\n", 2).last)
    assert_equal [{ loop: "al-1", hash: record.hash, store: store.id, files: 2, skipped: 0, nested: 0 }],
      @log.named("checkpoint_captured").first(1)
  end

  def test_gitignore_the_projects_info_exclude_the_excluded_dirs_the_protected_roots_and_the_store_never_enter_a_tree
    tree = make_checkout(@root, "src/a.rb" => "a", ".gitignore" => ".env\n")
    File.write(File.join(@root, ".git", "info", "exclude"), "scratch/\n")
    write(".env", "secret")
    write("scratch/s.txt", "s")
    write("artifacts/spill.log", "spill")
    write("vault/key", "k")
    write("src/b.rb", "b")
    store_dir = File.join(@root, ".rho-work", "checkpoints")
    store = Store.open(dir: store_dir, root: @root, log: @log, excluded: [File.join(@root, "artifacts")],
      protected_roots: [File.join(@root, "vault")])
    refute_equal tree, "", "the checkout has a HEAD tree"

    record = store.capture(loop: "al-1")

    assert_equal %w[.gitignore src/a.rb src/b.rb], tree_paths(store, record.hash)
    exclude = File.read(File.join(store.path, "info", "exclude"))
    assert_includes exclude, "scratch/"
    assert_includes exclude, "/artifacts/\n"
    assert_includes exclude, "/vault/\n"
    assert_includes exclude, "/.rho-work/checkpoints/#{store.id}/\n", "the store under the root excludes itself"
  end

  # ONE SPELLING, THE REAL PATH'S: a root named through a symlink (`/var` →
  # `/private/var`, a linked $HOME, `RHO_WORK_DIR` inside the root) real-paths to one
  # spelling, and the store's own dir and the excluded directories are compared against it
  # — so they must carry the same spelling, or the store's bare git dir and the spill land
  # in the tree. The store dir before its first init and a spill directory that lands only
  # during the turn are the cases: neither exists when the store is opened.
  def test_a_store_and_a_spill_named_through_a_symlink_never_enter_the_tree_even_before_they_exist
    real = File.join(@tmp, "real")
    FileUtils.mkdir_p(File.join(real, "root"))
    linked = File.join(@tmp, "linked")
    File.symlink(real, linked)
    root = File.join(linked, "root")
    write("src/a.rb", "a", root: root)
    store = Store.open(dir: File.join(root, ".rho-work", "checkpoints"), root: root, log: @log,
      excluded: [File.join(root, "artifacts")])
    write("artifacts/spill.log", "spill", root: root)

    record = store.capture(loop: "al-1")

    assert_equal ["src/a.rb"], tree_paths(store, record.hash), "neither the store nor the spill is in the tree"
    assert_equal File.join(real, "root"), store.root
    assert_equal File.join(real, "root", ".rho-work", "checkpoints"), store.dir, "the dir carries the root's spelling"
    exclude = File.read(File.join(store.path, "info", "exclude"))
    assert_includes exclude, "/.rho-work/checkpoints/#{store.id}/\n", "the store under the root excludes itself"
    assert_includes exclude, "/artifacts/\n", "the spill directory is excluded before it exists"
  end

  def test_a_checkout_root_gets_the_projects_objects_as_an_alternate_and_a_seeded_index_and_its_git_is_never_written
    head_tree = make_checkout(@root, "f.txt" => "hi", "big/blob.bin" => "\0" * (3 * 1024 * 1024))
    git_before = snapshot(File.join(@root, ".git"))

    store = open_store(max_file_bytes: 1024 * 1024)
    assert_equal "#{File.join(@root, ".git", "objects")}\n",
      File.read(File.join(store.path, "objects", "info", "alternates"))
    assert_empty store_git(store, "diff-files", "--name-only"), "the seeded index carries the stat cache"

    first = store.capture(loop: "al-1")
    assert_equal head_tree, first.hash, "an unmodified checkout captures HEAD's own tree, through the alternate"
    assert_equal [store_git(store, "rev-parse", "refs/checkpoints/al-1").strip], loose_objects(store),
      "the record's own commit is the ONE object written: the blobs and the tree are the alternate's"
    assert_empty first.skipped, "a TRACKED over-cap file is not skipped"

    # A tracked over-cap file grown past the cap is captured WHOLE;
    # an untracked one is skipped and excluded.
    File.open(File.join(@root, "big", "blob.bin"), "ab") { |f| f.write("more") }
    write("big/new.bin", "\0" * (2 * 1024 * 1024))
    second = store.capture(loop: "al-2")
    assert_equal ["big/new.bin"], second.skipped
    assert_equal %w[big/blob.bin f.txt], tree_paths(store, second.hash)
    assert_equal (3 * 1024 * 1024) + 4, store_git(store, "cat-file", "-s", "#{second.hash}:big/blob.bin").to_i
    assert_equal 5, loose_objects(store).length,
      "the changed blob, its subtree, the root tree and the second commit, beside the first commit"
    assert_equal git_before, snapshot(File.join(@root, ".git")), "the project's .git is byte-identical"
  end

  def test_a_subdirectory_of_a_checkout_is_a_plain_root_with_no_alternate
    make_checkout(@root, "f.txt" => "hi", "sub/g.txt" => "g")
    store = open_store(root: File.join(@root, "sub"))
    refute File.exist?(File.join(store.path, "objects", "info", "alternates"))
    assert_equal ["g.txt"], tree_paths(store, store.capture(loop: "al-1").hash)
  end

  def test_the_tree_cap_answers_a_final_skip_and_stages_nothing
    write("a.bin", "x" * 4096)
    write("b.bin", "y" * 4096)
    store = open_store(max_tree_bytes: 6000)

    skip = store.capture(loop: "al-1")

    assert_kind_of Skip, skip
    assert_predicate skip, :skip?
    assert_predicate skip, :final?
    assert_equal "tree_too_large", skip.reason
    assert_equal 8192, skip.bytes
    assert_equal 2, skip.files
    assert_equal({ "skipped" => "tree_too_large", "bytes" => 8192, "files" => 2 }, skip.key)
    assert_empty store.records
    assert_empty store_git(store, "ls-files"), "nothing was staged"
    assert_equal [{ loop: "al-1", store: store.id, reason: "tree_too_large", bytes: 8192, files: 2, detail: nil }],
      @log.named("checkpoint_skipped")
  end

  # THE TIMEOUT ARM (M-mf6): a stubbed git that answers init and config
  # and then hangs — with a child of its own — under a clock near zero.
  # The capture is skipped `timeout` (not final), and the GROUP is dead:
  # both pids the stub recorded are gone.
  def test_a_git_past_the_wall_clock_is_killed_as_a_group_and_the_capture_is_skipped_timeout
    write("a.txt", "a")
    pids = File.join(@tmp, "pids")
    stub = stub_git(<<~SH)
      echo $$ >> "#{pids}"
      sleep 30 &
      echo $! >> "#{pids}"
      wait
    SH
    store = open_store(git: stub, capture_timeout_seconds: 0.4)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    skip = store.capture(loop: "al-1")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_kind_of Skip, skip
    assert_equal "timeout", skip.reason
    refute_predicate skip, :final?
    assert_operator elapsed, :<, 5, "the wall clock bounds the capture"
    recorded = File.read(pids).split.map(&:to_i)
    assert_equal 2, recorded.length, "the stub and its child were both recorded"
    recorded.each { |pid| assert_process_gone(pid) }
    assert_equal ["timeout"], @log.named("checkpoint_skipped").map { |f| f[:reason] }
  end

  def test_a_git_that_fails_is_skipped_git_failed_with_the_stderr_tail_and_is_not_final
    write("a.txt", "a")
    stub = stub_git("echo 'boom: index is toast' >&2\nexit 3\n")
    store = open_store(git: stub)

    skip = store.capture(loop: "al-1")

    assert_equal "git_failed", skip.reason
    refute_predicate skip, :final?
    assert_includes skip.detail, "boom: index is toast"
  end

  def test_an_unchanged_tree_answers_the_same_hash_across_loops_and_the_second_capture_is_cheap
    write("a.txt", "a")
    write("b.txt", "b")
    store = open_store

    first = store.capture(loop: "al-1")
    second = store.capture(loop: "al-2")

    assert_equal first.hash, second.hash, "content-addressed: equal trees, equal hashes"
    refute_equal store_git(store, "rev-parse", "refs/checkpoints/al-1"), store_git(store, "rev-parse", "refs/checkpoints/al-2")
    assert_equal 2, store.records.length
    assert_empty store_git(store, "diff-files", "--name-only"), "the index is the stat cache"
  end

  def test_the_ref_is_create_only_so_a_loops_first_tree_wins_a_second_capture
    write("a.txt", "a")
    store = open_store
    first = store.capture(loop: "al-1")
    write("a.txt", "changed")

    again = store.capture(loop: "al-1")

    assert_equal first.hash, again.hash, "the store's record wins; the loop's first tree stands"
    assert_equal 1, store.records.length
    assert_equal 1, @log.named("checkpoint_captured").length, "nothing was captured the second time"
  end

  # THE UNDO IS ALWAYS A FRESH RECORD: two
  # restores in ONE request loop each capture the tree as it stands right
  # before them — two DIFFERENT undo hashes, each the pre-image of its own
  # restore, and undoing the SECOND brings back the tree from just before
  # it, byte for byte — while the loop's FIRST capture keeps the
  # create-only rule: a second `capture` under the name still answers the
  # first tree. `records(loop:)` lists the loop's undos, so `checkpoints
  # {loop: <request loop>}` finds every one.
  def test_two_restores_in_one_request_loop_answer_two_fresh_undos_each_the_tree_before_it
    write("a.txt", "a")
    store = open_store
    h1 = store.capture(loop: "al-1").hash

    write("a.txt", "b")
    before_first = snapshot
    first = store.restore(h1, undo_loop: "req-1")
    assert_kind_of Restored, first
    assert_equal "a", File.read(File.join(@root, "a.txt"))

    write("a.txt", "c")
    write("new.txt", "n")
    before_second = snapshot
    second = store.restore(h1, undo_loop: "req-1")
    assert_kind_of Restored, second

    refute_equal first.undo, second.undo, "the second restore's undo is the tree captured NOW, never the first's"
    assert_equal "b", store_git(store, "cat-file", "-p", "#{first.undo}:a.txt")
    assert_equal ["a.txt"], tree_paths(store, first.undo)
    assert_equal "c", store_git(store, "cat-file", "-p", "#{second.undo}:a.txt")
    assert_equal %w[a.txt new.txt], tree_paths(store, second.undo)
    undos = store.records(loop: "req-1")
    assert_equal [first.undo, second.undo], undos.map(&:hash), "both undos are listed under the request loop"
    assert_equal %w[req-1 req-1], undos.map(&:loop)
    assert_equal 3, store.records.length, "the loop's capture and the two undos"

    back = store.restore(second.undo, undo_loop: "req-1")
    assert_kind_of Restored, back
    assert_equal before_second, snapshot, "undoing the second restore is the tree from just before it"
    back_again = store.restore(first.undo, undo_loop: "req-1")
    assert_kind_of Restored, back_again
    assert_equal before_first, snapshot, "and the first undo still holds the tree from before the first"

    write("a.txt", "z")
    assert_equal h1, store.capture(loop: "al-1").hash, "the loop's first capture wins a second capture: create-only kept"
    assert_equal 1, @log.named("checkpoint_captured").count { |fields| fields[:loop] == "al-1" }
  end

  def test_a_loop_name_that_is_not_a_public_id_is_a_caller_bug
    store = open_store
    ["", "../x", "a/b", "x.lock", "bad name", "~"].each do |name|
      assert_raises(ArgumentError, name) { store.capture(loop: name) }
    end
  end

  def test_a_cancelled_task_passes_through_a_capture_as_its_own_exception_never_a_skip
    write("a.txt", "a")
    store = open_store
    context = Rho::Runner::ExecutionContext.new
    context.cancel
    Rho::Runner::ExecutionContext.with(context) do
      assert_raises(Rho::Runner::ExecutionContext::Cancelled) { store.capture(loop: "al-1") }
    end
    assert_empty @log.named("checkpoint_skipped")
  end

  # ---- restore ----

  # THE RESTORE PIN: EVERY path's bytes equal the pre-image, an ADDED file
  # is removed, an ignored file is untouched, a nested checkout added
  # during the turn keeps its .git and its uncommitted work, the stat
  # cache is fresh, and the undo is recorded under the request loop's id.
  def test_restore_puts_every_file_back_removes_the_added_keeps_the_ignored_and_the_gitlink_and_records_the_undo
    write("README.md", "readme")
    write("lib/a.rb", "one")
    write(".gitignore", ".env\n")
    write(".env", "secret")
    store = open_store
    h1 = store.capture(loop: "al-1").hash
    before = snapshot

    write("lib/a.rb", "two")
    write("lib/b.rb", "new")
    write(".env", "changed")
    make_checkout(File.join(@root, "nested"), "n.txt" => "n")
    write("nested/uncommitted.txt", "u")
    h2 = store.capture(loop: "al-2")
    assert_equal ["nested"], h2.nested
    assert_equal 4, h2.files, "four blobs; the gitlink is not a file"
    dirty = snapshot

    outcome = store.restore(h1, undo_loop: "req-1")

    assert_kind_of Restored, outcome
    assert_equal h1, outcome.restored
    assert_equal h2.hash, outcome.undo, "the undo is the tree as it was: byte-equal to al-2's, so the same hash"
    assert_equal 1, outcome.files
    assert_equal 1, outcome.removed
    assert_equal ["nested"], outcome.nested
    after = snapshot
    before.each do |path, bytes|
      next if path == ".env"

      assert_equal bytes, after[path], "#{path} is byte-identical to the pre-image"
    end
    assert_equal "changed", after.fetch(".env"), "an ignored path is in neither tree and is never touched"
    refute after.key?("lib/b.rb"), "the file the turn added is gone"
    assert_equal "u", after.fetch("nested/uncommitted.txt"), "the nested checkout's uncommitted work stands"
    assert_equal dirty.fetch("nested/.git/HEAD"), after.fetch("nested/.git/HEAD"), "its .git stands"
    assert_empty store_git(store, "diff-files", "--name-only"), "the stat cache is fresh after the restore"
    undo = store.records(loop: "req-1").first
    assert_equal h2.hash, undo.hash, "the undo record is under the request loop's id"
    assert_equal [{ loop: "req-1", store: store.id, from: h2.hash, to: h1, files: 1, removed: 1 }],
      @log.named("world_restored")

    # And back again: the undo restores the dirty tree byte for byte.
    back = store.restore(outcome.undo, undo_loop: "req-2")
    assert_kind_of Restored, back
    dirty.each { |path, bytes| assert_equal bytes, snapshot[path], path unless path == ".env" }
  end

  def test_restore_refuses_an_unknown_tree_and_writes_nothing
    write("a.txt", "a")
    store = open_store
    outcome = store.restore("0" * 40, undo_loop: "req-1")

    assert_kind_of Refusal, outcome
    assert_equal "checkpoint_unknown", outcome.code
    assert_equal "checkpoint_unknown: #{"0" * 40}", outcome.message
    assert_nil outcome.undo
    assert_nil store.records(loop: "req-1").first, "no undo was captured"
    assert_equal "a", File.read(File.join(@root, "a.txt"))
  end

  def test_restore_is_refused_whole_when_the_target_holds_an_entry_under_a_protected_root
    write("src/a.rb", "a")
    write("vault/key", "k")
    unprotected = open_store
    tree = unprotected.capture(loop: "al-1").hash
    assert_includes tree_paths(unprotected, tree), "vault/key"
    write("src/a.rb", "b")

    protected_store = open_store(protected_roots: [File.join(@root, "vault")])
    outcome = protected_store.restore(tree, undo_loop: "req-1")

    assert_kind_of Refusal, outcome
    assert_equal "restore_refused: protected_root_inside", outcome.message
    assert_equal "b", File.read(File.join(@root, "src", "a.rb")), "nothing was restored, not even src/"
    assert_nil protected_store.records(loop: "req-1").first, "refused before the undo"
    refute_includes tree_paths(protected_store, protected_store.capture(loop: "al-2").hash), "vault/key",
      "and the protected root never enters a new tree"
  end

  def test_a_restore_whose_undo_cannot_be_captured_is_not_performed
    write("a.txt", "a")
    store = open_store
    tree = store.capture(loop: "al-1").hash
    write("a.txt", "b" * 4096)

    capped = open_store(max_tree_bytes: 100)
    outcome = capped.restore(tree, undo_loop: "req-1")

    assert_equal "restore_refused", outcome.code
    assert_equal "restore_refused: the current tree could not be captured (tree_too_large); nothing was restored",
      outcome.message
    assert_equal "b" * 4096, File.read(File.join(@root, "a.txt"))
  end

  def test_restore_preserves_a_now_ignored_file_missing_from_the_undo_and_refuses_the_whole_tree
    write("a.txt", "old tracked")
    write("report.txt", "old report")
    store = open_store
    target = store.capture(loop: "before-delete").hash
    File.delete(File.join(@root, "report.txt"))
    store.capture(loop: "after-delete")
    write(".gitignore", "report.txt\n")
    write("report.txt", "current ignored report")
    write("a.txt", "current tracked")
    before = snapshot

    outcome = store.restore(target, undo_loop: "req-1")

    assert_kind_of Refusal, outcome
    assert_equal "restore_refused", outcome.code
    refute_nil outcome.undo
    refute_includes tree_paths(store, outcome.undo), "report.txt"
    assert_equal before, snapshot, "no file changes when an overwritten pre-image was not captured"
  end

  def test_restore_preserves_an_over_cap_untracked_file_missing_from_the_undo
    write("report.txt", "old report")
    store = open_store(max_file_bytes: 100)
    target = store.capture(loop: "before-delete").hash
    File.delete(File.join(@root, "report.txt"))
    store.capture(loop: "after-delete")
    write("report.txt", "p" * 200)
    before = snapshot

    outcome = store.restore(target, undo_loop: "req-1")

    assert_kind_of Refusal, outcome
    assert_equal "restore_refused", outcome.code
    assert_equal ["report.txt"], outcome.record.skipped
    refute_includes tree_paths(store, outcome.undo), "report.txt"
    assert_equal before, snapshot
  end

  def test_restore_preserves_ignored_files_in_a_directory_the_target_would_replace_with_a_file
    write("report", "old report")
    store = open_store
    target = store.capture(loop: "before-delete").hash
    File.delete(File.join(@root, "report"))
    store.capture(loop: "after-delete")
    write(".gitignore", "report/\n")
    write("report/current.txt", "current ignored report")
    before = snapshot

    outcome = store.restore(target, undo_loop: "req-1")

    assert_kind_of Refusal, outcome
    assert_equal "restore_refused", outcome.code
    assert_equal before, snapshot
  end

  def test_restore_preserves_an_uncaptured_file_obstructing_a_target_parent_directory
    write("report/old.txt", "old report")
    store = open_store
    target = store.capture(loop: "before-delete").hash
    FileUtils.rm_rf(File.join(@root, "report"))
    store.capture(loop: "after-delete")
    write(".gitignore", "report\n")
    write("report", "current ignored file")
    before = snapshot

    outcome = store.restore(target, undo_loop: "req-1")

    assert_kind_of Refusal, outcome
    assert_equal "restore_refused", outcome.code
    assert_equal before, snapshot
  end

  def test_restore_allows_a_fully_captured_directory_to_replace_a_file_and_back
    write("report", "original file")
    store = open_store
    target = store.capture(loop: "before-change").hash
    File.delete(File.join(@root, "report"))
    write("report/current.txt", "current captured report")
    before = snapshot

    restored = store.restore(target, undo_loop: "req-1")

    assert_kind_of Restored, restored
    assert_equal "original file", File.read(File.join(@root, "report"))
    assert_kind_of Restored, store.restore(restored.undo, undo_loop: "req-2")
    assert_equal before, snapshot
  end

  # ---- reads ----

  def test_records_record_and_present_read_the_refs_in_one_shape
    write("a.txt", "a")
    store = open_store
    first = store.capture(loop: "al-1")
    write("a.txt", "b")
    second = store.capture(loop: "al-2")

    rows = store.records
    assert_equal %w[al-1 al-2], rows.map(&:loop)
    assert_equal [first.hash, second.hash], rows.map(&:hash)
    assert rows.all?(&:present)
    assert_equal %w[loop hash store root captured_at files skipped nested outside ignored present],
      rows.first.to_row.keys
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, rows.first.captured_at)
    assert_equal [second.hash], store.records(loop: "al-2").map(&:hash)
    assert_equal first.hash, store.records(loop: "al-1").first.hash
    assert_nil store.records(loop: "al-9").first
    assert store.tree?(first.hash)
    refute store.tree?("f" * 40)
  end

  def test_changed_between_two_trees_is_a_diff_tree_with_no_work_tree_pass
    write("a.txt", "a")
    write("gone.txt", "g")
    store = open_store
    h1 = store.capture(loop: "al-1").hash
    write("a.txt", "A")
    write("new.txt", "n")
    File.delete(File.join(@root, "gone.txt"))
    h2 = store.capture(loop: "al-2").hash
    write("a.txt", "later")

    assert_equal [{ "status" => "M", "path" => "a.txt" }, { "status" => "D", "path" => "gone.txt" },
                  { "status" => "A", "path" => "new.txt" }], store.changed(from: h1, to: h2)
    assert_empty store.changed(from: h1, to: h1)
    assert_equal "later", File.read(File.join(@root, "a.txt")), "the work tree is not read, let alone touched"
  end

  def test_changed_since_stages_the_root_now_under_the_caps_and_diffs_it_against_the_tree
    write("a.txt", "a")
    store = open_store
    h1 = store.capture(loop: "al-1").hash
    write("a.txt", "A")
    write("new.txt", "n")

    assert_equal [{ "status" => "M", "path" => "a.txt" }, { "status" => "A", "path" => "new.txt" }],
      store.changed_since(h1)
    assert_empty store.records.reject { |r| r.loop == "al-1" }, "a read records nothing"

    write("huge.bin", "z" * 8192)
    capped = open_store(max_tree_bytes: 1000)
    skip = capped.changed_since(h1)
    assert_kind_of Skip, skip
    assert_equal "tree_too_large", skip.reason
  end

  # ---- prune ----

  def test_prune_drops_the_refs_older_than_the_retention_and_keeps_the_rest
    write("a.txt", "a")
    store = open_store
    old = store.capture(loop: "al-old")
    sleep 1.1
    write("a.txt", "b")
    fresh = store.capture(loop: "al-fresh")
    fresh_at = Time.iso8601(fresh.captured_at)

    assert_equal 1, store.prune(retention_days: 0, now: fresh_at - 0.5)

    assert_equal ["al-fresh"], store.records.map(&:loop)
    assert store.tree?(fresh.hash)
    assert_equal "b", store_git(store, "cat-file", "-p", "#{fresh.hash}:a.txt"), "gc kept what the ref keeps"
    refute store.tree?(old.hash), "gc --prune=now dropped the unreferenced tree"
    assert_equal 0, store.prune(retention_days: 7, now: fresh_at)
    assert_equal [{ store: store.id, removed: 1 }, { store: store.id, removed: 0 }], @log.named("checkpoints_pruned")
    assert_kind_of Integer, store.size_bytes
  end

  # ---- the lock pair ----

  def test_two_stores_on_one_root_and_many_threads_serialize_on_the_lock_and_every_capture_lands
    write("a.txt", "a")
    first = open_store
    second = open_store
    threads = 6.times.map do |i|
      Thread.new do
        Thread.current.report_on_exception = false
        store = i.even? ? first : second
        write("f#{i}.txt", "x")
        store.capture(loop: "al-#{i}")
      end
    end
    results = threads.map(&:value)

    assert results.all?(Record), results.map(&:class).inspect
    assert_equal 6, first.records.length
    assert_equal 6, second.records.length
    results.each { |record| assert_equal "tree", store_git(first, "cat-file", "-t", record.hash).strip }
  end

  # THE DOCTOR'S COUNT: the refs under the prefix — captures and undos — read through git
  # without an open, so packed refs count and a foreign ref does not; a directory that is
  # no store counts none.
  def test_record_count_reads_the_refs_under_the_prefix_without_opening_the_store
    write("a.txt", "a")
    store = open_store
    store.capture(loop: "al-1")
    write("a.txt", "b")
    store.capture(loop: "al-2")
    store.restore(store.records(loop: "al-1").first.hash, undo_loop: "req-1")
    store_git(store, "update-ref", "refs/heads/stranger", store_git(store, "rev-parse", "refs/checkpoints/al-1").strip)
    assert_equal 3, Store.record_count(store.path), "two captures and one undo; the stranger ref is nobody's"

    store_git(store, "pack-refs", "--all")
    assert_empty Dir.glob(File.join(store.path, "refs", "checkpoints", "*")), "the refs are packed"
    assert_equal 3, Store.record_count(store.path), "a packed ref is still a record"
    assert_equal 3, store.records.length, "the store's own listing agrees"

    config = File.mtime(File.join(store.path, "config"))
    Store.record_count(store.path)
    assert_equal config, File.mtime(File.join(store.path, "config")), "a count re-writes nothing"

    empty = File.join(@tmp, "not-a-store")
    FileUtils.mkdir_p(empty)
    assert_equal 0, Store.record_count(empty)
    assert_equal 0, Store.record_count(store.path, clock: -> { Float::INFINITY }), "a clock already past is no count"
  end

  # The restore's outcome carries the undo RECORD — the tool's reserved
  # key is `Record#key`, never a second spelling — and `undo` is its tree.
  def test_a_restore_answers_the_undo_record_whose_key_is_the_reserved_shape
    write("a.txt", "a")
    store = open_store
    tree = store.capture(loop: "al-1").hash
    write("a.txt", "b")

    outcome = store.restore(tree, undo_loop: "req-1")
    assert_kind_of Restored, outcome
    assert_kind_of Record, outcome.record
    assert_equal outcome.record.hash, outcome.undo
    assert_equal store.records(loop: "req-1").first, outcome.record, "the record the store lists under the request loop"
    assert_equal({ "hash" => outcome.undo, "store" => store.id }, outcome.record.key,
      "an undo captures the whole tree: no outside, no ignored on its key")
  end

  private

    # A stand-in git on the store's `git:` seam: `init`, `config` and the
    # project reads pass through to the real one; everything else runs
    # the body.
    def stub_git(body)
      real = `which git`.strip
      path = File.join(@tmp, "slow-git")
      File.write(path, <<~SH)
        #!/bin/sh
        case "$1" in
          init|config|rev-parse) exec #{real} "$@" ;;
        esac
        #{body}
      SH
      File.chmod(0o755, path)
      path
    end
end
