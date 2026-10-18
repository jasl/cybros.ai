require "test_helper"

class CheckpointCandidateBudgetTest < Minitest::Test
  Store = Rho::Runner::Checkpoints::Store

  def setup
    @directory = File.realpath(Dir.mktmpdir("rho-candidate-budget"))
    @root = File.join(@directory, "root")
    Dir.mkdir(@root)
    @stores = File.join(@directory, "stores")
  end

  def teardown
    FileUtils.rm_rf(@directory)
  end

  def test_stat_dirty_files_count_toward_the_budget_before_content_comparison
    path = File.join(@root, "a.txt")
    File.write(path, "original")
    first = Store.open(dir: @stores, root: @root).capture(run_public_id: "first")
    stamp = Time.now + 10
    File.utime(stamp, stamp, path)
    store = Store.open(dir: @stores, root: @root, max_tree_bytes: 0)

    outcome = store.capture(run_public_id: "limited")

    assert_equal "tree_too_large", outcome.reason
    assert_equal 8, outcome.bytes
    assert_equal 1, outcome.files
    assert_equal [first.hash], store.records.map(&:hash)
    assert_equal "original", File.read(path)
  end

  def test_dirty_nested_checkout_is_counted_without_capturing_its_files
    nested = File.join(@root, "nested")
    Dir.mkdir(nested)
    path = File.join(nested, "a.txt")
    File.write(path, "original")
    environment = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_AUTHOR_NAME" => "test", "GIT_AUTHOR_EMAIL" => "test@example.test",
      "GIT_COMMITTER_NAME" => "test", "GIT_COMMITTER_EMAIL" => "test@example.test" }
    [%w[init -q], %w[add --all], %w[commit -qm fixture]].each do |arguments|
      assert system(environment, "git", "-C", nested, *arguments, out: File::NULL, err: File::NULL)
    end
    first = Store.open(dir: @stores, root: @root).capture(run_public_id: "first")
    assert_equal ["nested"], first.nested
    File.write(path, "changed inside nested checkout")
    File.write(File.join(@root, "new.txt"), "xx")
    store = Store.open(dir: @stores, root: @root, max_tree_bytes: 1)

    outcome = store.capture(run_public_id: "limited")

    assert_equal "tree_too_large", outcome.reason
    assert_equal 2, outcome.bytes, "the gitlink weighs zero; only the new file has bytes"
    assert_equal 2, outcome.files, "the changed gitlink and new file are separate candidates"
    assert_equal [first.hash], store.records.map(&:hash)
    assert_equal "changed inside nested checkout", File.read(path)
  end
end
