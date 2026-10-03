require "test_helper"
require "tmpdir"
require "fileutils"

# WHAT THE MODEL IS TOLD ABOUT WHERE ITS TOOLS OPERATE — and the property
# that shapes the whole thing: every field is optional and NONE of them
# constrains anything. Working on one project from inside another is an
# ordinary thing to do, so this is a statement of what happens to be
# known, never a boundary.
class EnvironmentTest < Minitest::Test
  Environment = Rho::Runner::Environment

  def git(dir, *args)
    system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) ||
      raise("git #{args.join(" ")} failed")
  end

  def with_repo
    Dir.mktmpdir("rho-env") do |dir|
      real = File.realpath(dir)
      git(real, "init", "-q", "-b", "main")
      git(real, "config", "user.email", "t@example.test")
      git(real, "config", "user.name", "T")
      File.write(File.join(real, "a.txt"), "x")
      git(real, "add", "-A")
      git(real, "commit", "-qm", "first")
      yield real
    end
  end

  def test_only_the_root_is_required
    env = Environment.local(root: "/tmp/somewhere")

    assert_equal "/tmp/somewhere", env.root
    assert_nil env.working_directory
    assert_nil env.branch
    assert_nil env.worktree
    refute_predicate env, :known?, "a machine nobody told anything says nothing"
  end

  def test_a_checkout_contributes_its_branch
    with_repo do |dir|
      env = Environment.local(root: dir, working_directory: dir)

      assert_equal "main", env.branch
      assert_equal false, env.worktree
      assert_predicate env, :known?
    end
  end

  # A LINKED WORKTREE is the screenshot's chip: a second checkout of one
  # repository, where `.git` is a file pointing elsewhere.
  def test_a_linked_worktree_is_reported_as_one
    with_repo do |dir|
      linked = File.join(File.dirname(dir), "linked-#{File.basename(dir)}")
      git(dir, "worktree", "add", "-q", "-b", "side", linked)

      env = Environment.local(root: dir, working_directory: linked)

      assert_equal "side", env.branch
      assert_equal true, env.worktree
    ensure
      FileUtils.remove_entry(linked) if linked && File.directory?(linked)
    end
  end

  # A DIRECTORY THAT IS NOT A CHECKOUT IS NOT AN ERROR. Nothing here may
  # refuse, because the environment constrains nothing.
  def test_a_plain_directory_has_no_branch_and_that_is_fine
    Dir.mktmpdir("rho-plain") do |dir|
      env = Environment.local(root: dir, working_directory: dir)

      assert_equal File.realpath(dir), File.realpath(env.working_directory)
      assert_nil env.branch
      assert_nil env.worktree
    end
  end

  def test_a_directory_that_does_not_exist_answers_unknown_rather_than_raising
    env = Environment.local(root: "/tmp", working_directory: "/nope/nowhere")

    assert_equal "/nope/nowhere", env.working_directory
    assert_nil env.branch
  end

  # THE DISCOVERY NEVER RAISES, whatever it is pointed at. It runs while
  # a loop is being authored, so a git that is missing, wedged, or asked
  # about something that is not a directory must cost a branch name and
  # never the request.
  def test_discovery_answers_nil_rather_than_raising_for_anything
    ["/nope/nowhere", "/etc/hosts", "", "/"].each do |path|
      assert_nil Rho::Runner::Git.branch(path), path
      assert_nil Rho::Runner::Git.linked_worktree?(path), path
    end
  end

  # And a provider whose description raises costs that provider its
  # paragraph, not the authoring — the fail-open layer above this one.
  def test_a_raising_description_costs_only_that_provider
    registry = Rho::Runner::Extensions::Loader.call(builtin: [
      Rho::Runner::Extensions::Coding,
      Module.new do
        const_set(:NAME, "rho.loud")
        def self.register(api) = api.describe_environment { raise "boom" }
      end,
    ]).registry

    fragments = registry.environment_fragments(Environment.local(root: Dir.tmpdir))

    assert_equal ["rho.coding"], fragments.map { |f| f["extension"] },
      "the good provider still speaks"
  end

  def test_the_working_directory_is_expanded_because_operators_write_tildes
    env = Environment.local(root: "~", working_directory: "~")

    refute_includes env.root, "~"
    refute_includes env.working_directory, "~"
  end

  def test_root_is_the_working_directory_when_they_agree
    Dir.mktmpdir("rho-same") do |dir|
      assert_predicate Environment.local(root: dir, working_directory: dir),
        :root_is_working_directory?
      refute_predicate Environment.local(root: dir, working_directory: Dir.tmpdir),
        :root_is_working_directory?
    end
  end

  # THE REST OF THE ROOT SET: a conversation bound
  # with `--also` names more directories; the lead says so in one line
  # and the conventions walk still starts at the root. Absent by default,
  # expanded as the root is, and a statement like every other field.
  def test_additional_directories_are_told_in_one_line_and_absent_by_default
    env = Environment.local(root: "/tmp/somewhere")
    assert_equal [], env.directories
    refute_includes Rho::Runner::Extensions::Coding::Report.call(env), "Additional directories"

    told = Environment.local(root: "/tmp/somewhere", directories: ["~/other", "/tmp/third"])
    assert_equal [File.expand_path("~/other"), "/tmp/third"], told.directories
    assert_includes Rho::Runner::Extensions::Coding::Report.call(told).lines(chomp: true),
      "Additional directories: #{File.expand_path("~/other")}, /tmp/third."
  end
end

# THE RECORD'S VALUE, PARSED: rho's `store_entries` row
# at the conversation scope carries `{root, directories, anchor}`; the
# runner never reads the store — the host resolves and the runner receives
# this value, relayed or in process. Absent or malformed → nil, never a
# raise: a record a person edited by hand costs the conversation its
# placement (zero, with the notice), never the runner its claim.
class BindingTest < Minitest::Test
  Binding = Rho::Runner::Environment::Binding

  def test_parses_the_store_value_and_answers_it_back_as_written
    value = { "root" => "/tmp/project", "directories" => ["/tmp/other"], "anchor" => "conv-1" }

    binding = Binding.parse(value)

    assert_equal "/tmp/project", binding.root
    assert_equal ["/tmp/other"], binding.directories
    assert_equal "conv-1", binding.anchor
    assert_equal value, binding.to_h, "the compared tuple IS the value"
    assert_predicate binding, :frozen?
  end

  def test_directories_default_to_none_and_symbol_keys_are_read_as_string_keys
    assert_equal [], Binding.parse({ "root" => "/tmp/p", "anchor" => "c" }).directories
    assert_equal "/tmp/p", Binding.parse({ root: "/tmp/p", directories: [], anchor: "c" }).root
  end

  def test_absent_or_malformed_answers_nil
    assert_nil Binding.parse(nil)
    assert_nil Binding.parse("string")
    assert_nil Binding.parse({})
    assert_nil Binding.parse({ "root" => "", "anchor" => "c" })
    assert_nil Binding.parse({ "root" => 7, "anchor" => "c" })
    assert_nil Binding.parse({ "root" => "/tmp/p", "directories" => "not-a-list", "anchor" => "c" })
    assert_nil Binding.parse({ "root" => "/tmp/p", "directories" => [1], "anchor" => "c" })
    assert_nil Binding.parse({ "root" => "/tmp/p", "directories" => [], "anchor" => 3 })
  end

  def test_an_anchor_may_be_absent_on_a_value_written_around_rho
    binding = Binding.parse({ "root" => "/tmp/p" })

    assert_nil binding.anchor
    assert_equal({ "root" => "/tmp/p", "directories" => [], "anchor" => nil }, binding.to_h)
  end

  def test_the_value_is_a_value
    one = Binding.new(root: "/tmp/p", directories: [], anchor: "c")

    assert_equal one, Binding.parse(one.to_h)
    assert_equal one, Binding.new(root: "/tmp/p", directories: [], anchor: "c")
  end
end
