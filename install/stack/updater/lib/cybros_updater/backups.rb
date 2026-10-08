module CybrosUpdater
  class Backups
    DEFAULT_KEEP = 3
    HEADROOM_BYTES = 256 * 1024 * 1024
    Snapshot = Data.define(:id, :created_at, :size_bytes, :images) do
      def self.from_h(value)
        new(id: value.fetch("id"), created_at: value.fetch("created_at"), size_bytes: value.fetch("size_bytes"), images: value.fetch("images").map { |image| Image.from_h(image) })
      end

      def to_h
        { "id" => id, "created_at" => created_at, "size_bytes" => size_bytes, "images" => images.map(&:to_h) }
      end
    end

    attr_reader :directory

    def initialize(directory:, store:, keep: DEFAULT_KEEP)
      @installation = directory
      @directory = File.join(directory, "backups")
      @store = store
      @keep = keep
    end

    def create(docker:)
      assert_stopped(docker)
      images = docker.backup_images
      required = tree_size(@installation) + HEADROOM_BYTES
      ensure_space(docker, @installation, required)
      parent = private_directory("installations")
      id = SecureRandom.uuid_v7
      temporary = File.join(parent, ".#{id}.tmp")
      Dir.mkdir(temporary, 0o700)
      destination = File.join(temporary, "installation")
      size = copy_tree(@installation, destination, omit_runtime: true)
      size += freeze_images(destination, images)
      snapshot = Snapshot.new(id: id, created_at: Time.now.utc.iso8601(6), size_bytes: size, images: images)
      @store.atomic_write(File.join(temporary, "snapshot.json"), JSON.generate(snapshot.to_h) + "\n")
      File.rename(temporary, snapshot_path(id))
      sync_directory(parent)
      prune_snapshots
      snapshot_data(snapshot)
    ensure
      FileUtils.remove_entry(temporary) if temporary && File.exist?(temporary)
    end

    def restore(id, destination:, docker:)
      assert_stopped(docker)
      unless destination.start_with?("/") && File.directory?(destination) && Dir.empty?(destination)
        raise Error.new("invalid_request", "Restore requires an existing empty absolute destination directory.", status: 400)
      end
      destination = File.realpath(destination)
      backup_root = File.realpath(@directory)
      if destination == backup_root || destination.start_with?("#{backup_root}/")
        raise Error.new("invalid_request", "Restore outside the backup directory.", status: 400)
      end
      snapshot = read_snapshot(id)
      ensure_space(docker, destination, snapshot.size_bytes + HEADROOM_BYTES)
      copy_tree(File.join(snapshot_path(id), "installation"), destination, omit_runtime: false)
      { "id" => id, "directory" => destination, "started" => false }
    end

    def database(id, docker:)
      parent = private_directory("databases")
      path = database_path(id)
      # The completed filename is published only after pg_dumpall succeeds and
      # fsync finishes. Resume adopts it even if receipt persistence was interrupted.
      unless File.file?(path)
        temporary = File.join(parent, ".#{id}.#{SecureRandom.hex(4)}.tmp")
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          docker.dump_database(file)
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
        sync_directory(parent)
        prune_databases
      end
      database_metadata(id)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def available?(id) = File.file?(database_path(id))

    def list
      { "installations" => snapshot_ids.map { |id| snapshot_data(read_snapshot(id)) },
        "databases" => database_ids.map { |id| database_metadata(id).to_h.merge("operation_id" => id) }, "keep" => @keep }
    end

    private

    def assert_stopped(docker)
      migrators = @store.load.fetch("receipts").map { |receipt| receipt.fetch("migrator_name") }
      docker.assert_stopped(migrators: migrators)
    end

    def ensure_space(docker, path, required)
      if docker.available_bytes(path) < required
        raise Error.new("insufficient_space", "The destination has less free space than the estimated backup size and headroom.")
      end
    end

    def private_directory(name)
      [@directory, File.join(@directory, name)].each do |path|
        FileUtils.mkdir_p(path, mode: 0o700)
        unless (File.stat(path).mode & 0o077).zero?
          raise Error.new("backup_unavailable", "Backup directories must be private (mode 0700).")
        end
      end
      File.join(@directory, name)
    end

    def tree_size(path, relative = "")
      info = File.lstat(path)
      if info.directory?
        Dir.children(path).sum do |name|
          child = relative.empty? ? name : File.join(relative, name)
          excluded?(child) ? 0 : tree_size(File.join(path, name), child)
        end
      elsif info.file?
        info.size + 4096
      else
        4096
      end
    end

    def copy_tree(source, destination, omit_runtime:, relative: "")
      info = File.lstat(source)
      if info.directory?
        Dir.mkdir(destination, 0o700) unless File.directory?(destination)
        size = Dir.children(source).sum do |name|
          child = relative.empty? ? name : File.join(relative, name)
          if omit_runtime && excluded?(child)
            0
          else
            copy_tree(File.join(source, name), File.join(destination, name), omit_runtime: omit_runtime, relative: child)
          end
        end
        File.chown(info.uid, info.gid, destination)
        File.chmod(info.mode & 0o7777, destination)
        File.utime(info.atime, info.mtime, destination)
        sync_directory(destination)
        size
      elsif info.file? || info.symlink?
        # FileUtils copies a link as a link; an external target is not backup data.
        FileUtils.copy_entry(source, destination, true, false)
        File.open(destination, File::RDONLY, &:fsync) if info.file?
        info.file? ? info.size : 0
      else
        raise Error.new("backup_unavailable", "The installation contains a non-file entry outside its runtime directories. Remove that transient entry before backup.")
      end
    end

    def excluded?(relative)
      %w[backups data/updater-ipc data/rho/home/tmp .env.new secrets.env.new].include?(relative) ||
        relative.match?(/\Aimages\.env\.[^\/]+\.tmp\z/) || relative.match?(/\Adata\/updater\/state\.json\.[^\/]+\.tmp\z/)
    end

    def freeze_images(destination, images)
      references = images.to_h { |image| [image.name, image.reference] }
      environment = File.join(destination, ".env")
      images_file = File.join(destination, "images.env")
      before = File.size(environment) + (File.file?(images_file) ? File.size(images_file) : 0)
      contents = File.readlines(environment).reject { |line| line.start_with?("CYBROS_UPDATER_IMAGE=", "CYBROS_POSTGRES_IMAGE=") }.join
      contents << "\n" unless contents.end_with?("\n")
      contents << "CYBROS_UPDATER_IMAGE='#{references.fetch("updater")}'\nCYBROS_POSTGRES_IMAGE='#{references.fetch("db")}'\n"
      @store.atomic_write(environment, contents, owner: File.stat(environment))
      contents = "CYBROS_NEXUS_IMAGE='#{references.fetch("nexus")}'\nCYBROS_RHO_IMAGE='#{references.fetch("rho")}'\n"
      @store.atomic_write(images_file, contents, owner: File.stat(environment))
      File.size(environment) + File.size(images_file) - before
    end

    def read_snapshot(id)
      path = File.join(snapshot_path(id), "snapshot.json")
      unless File.file?(path)
        raise Error.new("not_found", "The installation backup is unavailable.", status: 404)
      end
      Snapshot.from_h(JSON.parse(File.read(path)))
    end

    def snapshot_data(snapshot)
      snapshot.to_h.slice("id", "created_at", "size_bytes").merge("path" => snapshot_path(snapshot.id))
    end

    def database_metadata(id)
      file = File.stat(database_path(id))
      DatabaseBackup.new(created_at: file.mtime.utc.iso8601(6), size_bytes: file.size, available: true)
    end

    def snapshot_ids
      parent = File.join(@directory, "installations")
      if File.directory?(parent)
        Dir.children(parent).select { |id| id.match?(UUID) && File.file?(File.join(parent, id, "snapshot.json")) }
          .sort_by { |id| [File.mtime(File.join(parent, id, "snapshot.json")), id] }.reverse
      else
        []
      end
    end

    def database_ids
      parent = File.join(@directory, "databases")
      if File.directory?(parent)
        Dir.children(parent).filter_map do |name|
          id = name.delete_suffix(".sql")
          id if name.end_with?(".sql") && id.match?(UUID) && File.file?(File.join(parent, name))
        end.sort_by { |id| [File.mtime(database_path(id)), id] }.reverse
      else
        []
      end
    end

    def prune_snapshots
      snapshot_ids.drop(@keep).each { |id| FileUtils.remove_entry(snapshot_path(id)) }
    end

    def prune_databases
      database_ids.drop(@keep).each { |id| File.unlink(database_path(id)) }
    end

    def snapshot_path(id) = File.join(@directory, "installations", id)
    def database_path(id) = File.join(@directory, "databases", "#{id}.sql")
    def sync_directory(path) = File.open(path, File::RDONLY, &:fsync)
  end
end
