require_relative "fixtures"

class CheckpointsCompressionTest < Minitest::Test
  include CheckpointFixtures

  def database(store)
    db = SQLite3::Database.new(File.join(store.path, Rho::Runner::Checkpoints::Store::DATABASE_FILE), readonly: true)
    yield db
  ensure
    db&.close
  end

  def test_mixed_raw_and_compressed_content_restores_exact_bytes_modes_and_links_after_reopening
    values = { "executable" => "binary\0\xff".b * 4096, "random" => Random.new(1846).bytes(8192),
      "short" => "\0".b, "empty" => "".b }
    values.each { |name, bytes| write(name, bytes) }
    executable = File.join(@root, "executable")
    File.chmod(0o755, executable)
    target = "missing/" * 24
    File.symlink(target, File.join(@root, "link"))
    original = disk
    store = open_store
    first = store.capture(run_public_id: "first")
    refute_predicate first, :skip?

    database(store) do |db|
      values.merge("link" => target.b).each do |name, bytes|
        payload, compressed = db.get_first_row("SELECT data, compressed FROM blobs WHERE hash = ?", [Digest::SHA256.hexdigest(bytes)])
        if %w[executable link].include?(name)
          assert_equal 1, compressed, name
          assert_operator payload.bytesize, :<, bytes.bytesize, name
        else
          assert_equal 0, compressed, name
          assert_equal bytes, payload, name
        end
      end
    end

    values.each_key { |name| write(name, "changed #{name}") }
    File.chmod(0o644, executable)
    File.unlink(File.join(@root, "link"))
    File.symlink("short", File.join(@root, "link"))
    changed = disk
    store = open_store
    restored = store.restore(first.hash, undo_loop: "restore")
    assert_kind_of Rho::Runner::Checkpoints::Restored, restored
    assert_equal original, disk
    assert_equal 0o755, File.stat(executable).mode & 0o777
    assert_kind_of Rho::Runner::Checkpoints::Restored, open_store.restore(restored.undo, undo_loop: "undo")
    assert_equal changed, disk
    assert_equal 0o644, File.stat(executable).mode & 0o777
  end

  def test_identical_content_across_paths_and_captures_occupies_one_blob_and_remains_restorable
    bytes = "shared\0\xff".b * 4096
    write("first", bytes)
    store = open_store
    first = store.capture(run_public_id: "first")
    write("second", bytes)
    write("nested/third", bytes)
    second = store.capture(run_public_id: "second")
    repeated = store.capture(run_public_id: "unchanged")
    assert_equal second.hash, repeated.hash
    assert_equal first, store.capture(run_public_id: "first")
    database(store) do |db|
      assert_equal 1, db.get_first_value("SELECT count(*) FROM blobs")
      assert_equal Digest::SHA256.hexdigest(bytes), db.get_first_value("SELECT hash FROM blobs")
      assert_equal 3, db.get_first_value("SELECT count(*) FROM records")
    end

    restored = store.restore(first.hash, undo_loop: "restore")
    assert_equal({ "first" => ["file", bytes] }, disk)
    store.restore(restored.undo, undo_loop: "undo")
    assert_equal %w[first nested/third second], disk.keys.sort
    assert_equal [["file", bytes]], disk.values.uniq
  end

  def test_opening_an_existing_raw_store_preserves_history_and_accepts_new_compressed_content
    original = "old uncompressed content\0".b * 4096
    write("file", original)
    store = open_store
    first = store.capture(run_public_id: "first")
    path = File.join(store.path, Rho::Runner::Checkpoints::Store::DATABASE_FILE)
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE raw_blobs (hash TEXT PRIMARY KEY, data BLOB NOT NULL)")
    db.execute("INSERT INTO raw_blobs(hash, data) VALUES (?, ?)", [Digest::SHA256.hexdigest(original), SQLite3::Blob.new(original)])
    db.execute("DROP TABLE blobs")
    db.execute("ALTER TABLE raw_blobs RENAME TO blobs")
    db.close

    store = open_store
    assert_equal [first], store.records
    database(store) do |saved|
      assert_equal [original, 0], saved.get_first_row("SELECT data, compressed FROM blobs")
    end
    changed = "new compressible content\0".b * 4096
    write("file", changed)
    second = store.capture(run_public_id: "second")
    refute_predicate second, :skip?
    database(store) do |saved|
      assert_equal 1, saved.get_first_value("SELECT compressed FROM blobs WHERE hash = ?", [Digest::SHA256.hexdigest(changed)])
    end
    restored = open_store.restore(first.hash, undo_loop: "restore")
    assert_equal original, File.binread(File.join(@root, "file"))
    open_store.restore(restored.undo, undo_loop: "undo")
    assert_equal changed, File.binread(File.join(@root, "file"))
  ensure
    db&.close unless db&.closed?
  end

  def test_a_damaged_compressed_blob_returns_a_refusal_with_a_restorable_undo
    original = "original content\0".b * 4096
    write("file", original)
    store = open_store
    first = store.capture(run_public_id: "first")
    changed = "changed content\0".b * 4096
    write("file", changed)
    db = SQLite3::Database.new(File.join(store.path, Rho::Runner::Checkpoints::Store::DATABASE_FILE))
    db.execute("UPDATE blobs SET data = ? WHERE hash = ?", [SQLite3::Blob.new("damaged"), Digest::SHA256.hexdigest(original)])
    db.close

    refused = store.restore(first.hash, undo_loop: "damaged")
    assert_kind_of Rho::Runner::Checkpoints::Refusal, refused
    assert_equal "restore_failed", refused.code
    assert_equal store.records(run_public_id: "damaged").fetch(0).hash, refused.undo
    assert_kind_of Rho::Runner::Checkpoints::Restored, open_store.restore(refused.undo, undo_loop: "undo")
    assert_equal changed, File.binread(File.join(@root, "file"))
  ensure
    db&.close unless db&.closed?
  end
end
