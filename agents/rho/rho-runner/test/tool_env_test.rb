require "test_helper"

# The value a tool closes over. Its one host-owned member is the process
# table, and a runner built with no daemon behind it carries none.
class ToolEnvTest < Minitest::Test
  def test_the_process_table_defaults_to_nil_for_a_standalone_runner
    env = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: File.join(Dir.tmpdir, "a"))

    assert_nil env.processes
    assert env.frozen?
  end

  # The watcher's channel (executor.md "Progress"): a tail reaches the one
  # task's context on this thread, and says nothing to nobody outside one.
  def test_report_progress_reaches_the_current_context_and_is_silent_outside_one
    env = Rho::Runner::ToolEnv.new(root: Dir.pwd, artifacts_dir: File.join(Dir.pwd, ".artifacts"))
    assert_nil env.report_progress("outside a task")

    progress = Rho::Runner::Progress.new(post: ->(_text) { true }, clock: -> { 0.0 })
    context = Rho::Runner::ExecutionContext.new(progress: progress, clock: -> { 0.0 })
    Rho::Runner::ExecutionContext.with(context) { env.report_progress("3/9") }
    assert_predicate progress, :pending?
  end

  def test_a_host_hands_its_table_in
    table = Object.new
    env = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: File.join(Dir.tmpdir, "a"), processes: table)

    assert_same table, env.processes
  end

  # THE HOST'S CHECKPOINT STORE: opened once by the host and
  # handed here so the two tools reach the store the capture hook writes;
  # a standalone runner has nowhere to keep a pre-image and carries nil.
  def test_the_checkpoint_store_defaults_to_nil_and_a_host_hands_its_own_in
    env = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: File.join(Dir.tmpdir, "a"))
    assert_nil env.checkpoints

    store = Object.new
    env = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: File.join(Dir.tmpdir, "a"), checkpoints: store)
    assert_same store, env.checkpoints
    assert env.frozen?
  end

  # WHERE A ROOT'S CAPTURES LIVE: a bash spill, a screenshot, a
  # page's overflow are rho's own bookkeeping, and rho writes the person's
  # files on the person's word only — so they are placed under the host's
  # WORK dir, `<work>/artifacts/<digest of the root>/`, never under the
  # root (an `artifacts/` in a project is noise in every `git status` the
  # model runs, and a stray directory in a graded tree). Keyed per root:
  # two roots never share a directory, one root always finds its own.
  def test_a_roots_artifacts_are_placed_under_the_work_dir_never_under_the_root
    Dir.mktmpdir("rho-tool-env") do |tmp|
      work = File.join(tmp, "work")
      one = File.join(tmp, "one")
      two = File.join(tmp, "two")
      FileUtils.mkdir_p([one, two])

      placed = Rho::Runner::ToolEnv.artifacts_dir_for(root: one, work_dir: work)

      assert placed.start_with?("#{File.expand_path(work)}/artifacts/"), "not under the work dir: #{placed}"
      refute placed.start_with?("#{one}/"), "rho's bookkeeping inside the person's tree: #{placed}"
      assert_equal placed, Rho::Runner::ToolEnv.artifacts_dir_for(root: one, work_dir: work), "one root, one directory"
      refute_equal placed, Rho::Runner::ToolEnv.artifacts_dir_for(root: two, work_dir: work), "two roots never share"
      assert_equal placed, Rho::Runner::ToolEnv.new(root: one, artifacts_dir: placed).artifacts_dir
    end
  end

  # THE ROOT SET: the rest of a conversation's
  # directories ride the env beside the root — absent by default; nothing
  # confines a path on them; `in_roots?` is the one predicate the port
  # will route on (E2), a spelled-prefix test over `[root, *directories]`.
  def test_directories_default_to_none_and_are_spelled_and_frozen
    env = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: File.join(Dir.tmpdir, "a"))
    assert_equal [], env.directories
    assert_nil env.documents_root

    with = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: File.join(Dir.tmpdir, "a"),
      directories: ["~/other", "/tmp/../tmp/third"], documents_root: "/tmp/docs")
    assert_equal [File.expand_path("~/other"), "/tmp/third"], with.directories
    assert_predicate with.directories, :frozen?
    assert_equal "/tmp/docs", with.documents_root
    assert with.frozen?
  end

  def test_in_roots_is_a_spelled_prefix_over_the_root_set
    Dir.mktmpdir("rho-tool-env") do |tmp|
      real = File.realpath(tmp)
      root = File.join(real, "root")
      other = File.join(real, "other")
      FileUtils.mkdir_p([root, other, File.join(real, "elsewhere")])
      File.symlink(other, File.join(real, "link"))
      env = Rho::Runner::ToolEnv.new(root: root, artifacts_dir: File.join(real, "a"), directories: [other])

      assert env.in_roots?(root)
      assert env.in_roots?(File.join(root, "lib", "a.rb")), "a path that does not exist yet is judged by its spelling"
      assert env.in_roots?("lib/a.rb"), "a relative path resolves against the root first"
      assert env.in_roots?(File.join(other, "b.rb"))
      assert env.in_roots?(File.join(real, "link", "b.rb")), "a symlinked spelling of a member is inside"
      refute env.in_roots?(File.join(real, "elsewhere", "c.rb"))
      refute env.in_roots?(File.join(root, "..", "elsewhere", "c.rb")), "`..` is judged on the resolved spelling"
      refute env.in_roots?("#{root}-sibling/x"), "a sibling sharing the prefix is outside"
    end
  end

  def test_the_spelling_is_the_real_path_of_the_existing_prefix
    Dir.mktmpdir("rho-tool-env") do |tmp|
      real = File.realpath(tmp)
      File.symlink(real, File.join(real, "self"))

      assert_equal File.join(real, "new", "file"), Rho::Runner::ToolEnv.spelled(File.join(real, "self", "new", "file"))
      assert_equal "/nope/nowhere", Rho::Runner::ToolEnv.spelled("/nope/nowhere/")
      assert_equal File.expand_path("~"), Rho::Runner::ToolEnv.spelled("~")
    end
  end

  def test_spelling_observes_symlink_retargeting_and_disappearance
    Dir.mktmpdir("rho-tool-env") do |tmp|
      real = File.realpath(tmp)
      one = File.join(real, "one")
      two = File.join(real, "two")
      link = File.join(real, "link")
      FileUtils.mkdir_p([one, two])
      File.symlink(one, link)

      assert_equal File.join(one, "new", "file"), Rho::Runner::ToolEnv.spelled(File.join(link, "new", "file"))

      File.unlink(link)
      File.symlink(two, link)
      assert_equal File.join(two, "new", "file"), Rho::Runner::ToolEnv.spelled(File.join(link, "new", "file"))

      File.unlink(link)
      assert_equal File.join(link, "new", "file"), Rho::Runner::ToolEnv.spelled(File.join(link, "new", "file"))
    end
  end
end
