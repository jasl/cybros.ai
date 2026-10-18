require "test_helper"

module CheckpointFixtures
  def setup
    @tmp = File.realpath(Dir.mktmpdir("snapshot-contract"))
    @root = File.join(@tmp, "root")
    Dir.mkdir(@root)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def open_store(**options)
    Rho::Runner::Checkpoints::Store.open(dir: File.join(@tmp, "stores"), root: @root, **options)
  end

  def write(name, value)
    path = File.join(@root, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, value)
  end

  def disk
    files = {}
    Find.find(@root) do |path|
      next if path == @root
      name = path.delete_prefix("#{@root}/")
      if File.symlink?(path)
        files[name] = ["link", File.readlink(path)]
      elsif File.file?(path)
        files[name] = ["file", File.binread(path)]
      end
    end
    files
  end

  def checkout(directory)
    environment = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1", "GIT_AUTHOR_NAME" => "fixture",
      "GIT_AUTHOR_EMAIL" => "fixture@example.test", "GIT_COMMITTER_NAME" => "fixture", "GIT_COMMITTER_EMAIL" => "fixture@example.test" }
    [%w[init -q], %w[add --all], %w[commit -qm fixture]].each do |args|
      assert system(environment, "git", "-C", directory, *args, out: File::NULL, err: File::NULL)
    end
  end
end
