require "minitest/autorun"
require "tmpdir"
require_relative "../lib/cybros_updater"

class UpdaterBackupsTest < Minitest::Test
  class FakeDocker
    attr_accessor :running, :dump_failure, :free_bytes
    attr_reader :dumps

    def initialize
      @free_bytes = 1024 * 1024 * 1024
      @dumps = 0
    end

    def assert_stopped(migrators:)
      if @running
        raise CybrosUpdater::Error.new("backup_unavailable", "Stop the installation first.")
      end
    end

    def backup_images
      %w[nexus rho db updater].map { |name| CybrosUpdater::Image.new(name: name, reference: "registry.example/#{name}@sha256:#{"a" * 64}", version: nil) }
    end

    def available_bytes(_directory) = @free_bytes

    def dump_database(file)
      @dumps += 1
      file.write("CREATE DATABASE preserved; -- synthetic-private-database\n")
      if @dump_failure
        raise CybrosUpdater::Error.new("backup_failed", "The database export failed.")
      end
    end
  end

  def setup
    @root = Dir.mktmpdir("backup installation ")
    @directory = File.join(@root, "source")
    FileUtils.mkdir_p(File.join(@directory, "data", "rho", "work"))
    FileUtils.mkdir_p(File.join(@directory, "data", "updater-ipc"))
    FileUtils.mkdir_p(File.join(@directory, "data", "updater"))
    File.write(File.join(@directory, ".env"), "CYBROS_PROJECT_NAME='original'\nCYBROS_UPDATER_IMAGE='old:latest'\n")
    File.write(File.join(@directory, "secrets.env"), "PRIVATE='synthetic-secret'\n", mode: "w", perm: 0o600)
    File.write(File.join(@directory, "images.env"), "CYBROS_NEXUS_IMAGE='old:latest'\n")
    File.write(File.join(@directory, "data", "rho", "work", "document.txt"), "preserved file\n")
    File.write(File.join(@directory, "data", "updater", "state.json"), JSON.generate({ "receipts" => [] }))
    File.write(File.join(@directory, "data", "updater", "state.json.abcd.tmp"), "incomplete")
    File.write(File.join(@directory, "data", "updater-ipc", "temporary"), "socket directory")
    File.write(File.join(@directory, ".env.new"), "incomplete configuration")
    @external = File.join(@root, "external")
    FileUtils.mkdir_p(@external)
    File.write(File.join(@external, "outside.txt"), "not part of the installation")
    File.symlink(@external, File.join(@directory, "data", "rho", "work", "external-link"))
    @docker = FakeDocker.new
    @store = CybrosUpdater::Store.new(File.join(@directory, "data", "updater"))
    @backups = CybrosUpdater::Backups.new(directory: @directory, store: @store, keep: 2)
  end

  def teardown
    @store.close
    FileUtils.remove_entry(@root)
  end

  def test_stopped_snapshot_restores_data_modes_links_and_all_four_image_pins_to_an_empty_directory
    snapshot = @backups.create(docker: @docker)
    assert_match CybrosUpdater::UUID, snapshot.fetch("id")
    assert_equal 0o700, File.stat(File.join(@directory, "backups")).mode & 0o777
    source = File.join(snapshot.fetch("path"), "installation")
    refute File.exist?(File.join(source, "backups"))
    refute File.exist?(File.join(source, "data", "updater-ipc"))
    refute File.exist?(File.join(source, "data", "updater", "state.json.abcd.tmp"))
    refute File.exist?(File.join(source, ".env.new"))
    assert File.symlink?(File.join(source, "data", "rho", "work", "external-link"))
    assert_equal @external, File.readlink(File.join(source, "data", "rho", "work", "external-link"))
    assert_equal "CYBROS_NEXUS_IMAGE='old:latest'\n", File.read(File.join(@directory, "images.env"))

    destination = File.join(@root, "restored")
    Dir.mkdir(destination)
    result = @backups.restore(snapshot.fetch("id"), destination: destination, docker: @docker)
    assert_equal false, result.fetch("started")
    assert_equal File.realpath(destination), result.fetch("directory")
    assert_equal "preserved file\n", File.read(File.join(destination, "data", "rho", "work", "document.txt"))
    assert_equal 0o600, File.stat(File.join(destination, "secrets.env")).mode & 0o777
    assert File.symlink?(File.join(destination, "data", "rho", "work", "external-link"))
    %w[nexus rho].each do |name|
      assert_includes File.read(File.join(destination, "images.env")), "registry.example/#{name}@sha256:"
    end
    %w[db updater].each do |name|
      assert_includes File.read(File.join(destination, ".env")), "registry.example/#{name}@sha256:"
    end
    assert_equal 1, File.read(File.join(destination, ".env")).scan(/^CYBROS_UPDATER_IMAGE=/).size
    assert_raises(CybrosUpdater::Error) { @backups.restore(snapshot.fetch("id"), destination: destination, docker: @docker) }
    assert_equal "not part of the installation", File.read(File.join(@external, "outside.txt"))
  end

  def test_full_backup_refuses_running_services_or_insufficient_space_without_a_completed_snapshot
    @docker.running = true
    assert_equal "backup_unavailable", assert_raises(CybrosUpdater::Error) { @backups.create(docker: @docker) }.code
    @docker.running = false
    @docker.free_bytes = 1
    assert_equal "insufficient_space", assert_raises(CybrosUpdater::Error) { @backups.create(docker: @docker) }.code
    assert_empty @backups.list.fetch("installations")
  end

  def test_database_backup_is_private_atomic_and_reused_after_success
    id = SecureRandom.uuid_v7
    @docker.dump_failure = true
    assert_raises(CybrosUpdater::Error) { @backups.database(id, docker: @docker) }
    assert_empty @backups.list.fetch("databases")
    assert_empty Dir.glob(File.join(@directory, "backups", "databases", "*.tmp"))
    @docker.dump_failure = false
    backup = @backups.database(id, docker: @docker)
    assert backup.available
    path = File.join(@directory, "backups", "databases", "#{id}.sql")
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_includes File.read(path), "synthetic-private-database"
    assert_equal backup, @backups.database(id, docker: @docker)
    assert_equal 2, @docker.dumps
  end

  def test_retention_only_removes_older_completed_tool_backups_after_a_new_success
    original = @backups.create(docker: @docker)
    kept = @backups.create(docker: @docker)
    manual = File.join(@directory, "backups", "installations", "operator-notes")
    FileUtils.mkdir_p(manual)
    @docker.free_bytes = 0
    assert_raises(CybrosUpdater::Error) { @backups.create(docker: @docker) }
    assert File.directory?(original.fetch("path"))
    @docker.free_bytes = 1024 * 1024 * 1024
    newest = @backups.create(docker: @docker)
    assert_equal [newest.fetch("id"), kept.fetch("id")], @backups.list.fetch("installations").map { |entry| entry.fetch("id") }
    refute File.exist?(original.fetch("path"))
    assert File.directory?(manual)

    ids = 3.times.map { SecureRandom.uuid_v7.tap { |id| @backups.database(id, docker: @docker) } }
    refute @backups.available?(ids.first)
    assert_equal ids.drop(1).reverse, @backups.list.fetch("databases").map { |entry| entry.fetch("operation_id") }
  end
end
