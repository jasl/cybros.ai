require "test_helper"

# Where rho keeps things. One RHO_HOME is one Nexus, so the
# facts that matter are: the binding is recorded and enforced, every directory
# is private from the moment it exists, and the durable half of the tree is
# separable from the disposable and the rebuildable halves.
class HomeTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-home")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def home(base_url = "https://nexus.example", root: @root)
    Rho::Home.resolve(base_url: base_url, root: root)
  end

  # ---- the address ----

  # Spellings of the same address must be one home, or a daemon started with a
  # trailing slash would be refused by the binding guard against a home it
  # actually belongs to.
  def test_equivalent_spellings_of_one_address_are_one_home
    home.prepare

    ["https://nexus.example/", "https://NEXUS.example", "https://nexus.example:443"].each do |spelling|
      assert_equal "https://nexus.example", home(spelling).base_url, "#{spelling} must be the same home"
    end
  end

  def test_a_path_prefix_is_part_of_the_address
    refute_equal home("https://nexus.example").base_url, home("https://nexus.example/kernel").base_url
  end

  def test_an_address_that_is_not_an_absolute_http_url_is_refused
    ["nexus.example", "ftp://nexus.example", "", "https://"].each do |bad|
      assert_raises(Rho::ConfigurationError) { home(bad) }
    end
  end

  # ---- the binding guard ----

  # The point of deleting the per-Nexus layer: a home holds one Nexus, so
  # naming another must be refused rather than quietly opening a second
  # credential tree beside the first.
  def test_a_bound_home_refuses_a_different_nexus
    home.prepare

    error = assert_raises(Rho::ConfigurationError) { home("https://other.example") }
    assert_includes error.message, "https://nexus.example"
    assert_includes error.message, "https://other.example"
    assert_includes error.message, "different RHO_HOME"
  end

  def test_a_fresh_home_accepts_any_nexus_and_remembers_it
    assert_nil Rho::Home.bound_address(root: @root)

    home("https://other.example").prepare

    assert_equal "https://other.example", Rho::Home.bound_address(root: @root)
  end

  # Preparing twice must not rewrite it: for a given directory the address is
  # fixed once the first connection ceremony could have started against it.
  def test_the_binding_is_written_once
    resolved = home.prepare
    first = File.read(resolved.binding_path)
    resolved.prepare

    assert_equal first, File.read(resolved.binding_path)
  end

  def test_an_unreadable_binding_reports_no_binding_rather_than_raising
    File.write(File.join(@root, "nexus.json"), "{ not json")

    assert_nil Rho::Home.bound_address(root: @root)
  end

  # A hosted product has one address that does not change, so it is the answer
  # when nobody supplies one. Development is the unstable case, which is what
  # the flag and the environment variable exist for.
  def test_there_is_a_default_nexus
    assert_equal "https://cybros.ai", Rho::Home::DEFAULT_NEXUS_URL
    assert_equal(
      Rho::Home::DEFAULT_NEXUS_URL,
      Rho::Home.canonical_base_url(Rho::Home::DEFAULT_NEXUS_URL),
      "the default must already be in canonical form, or it would fail its own binding guard"
    )
  end

  # ---- the shape of the tree ----

  # The root holds durable things; tmp/ holds what a boot rebuilds, log/ holds
  # history. Staging is deliberately at the root, not in tmp/: deleting a
  # connection in flight costs a human a browser ceremony.
  def test_the_disposable_and_the_durable_are_separated
    resolved = home

    [resolved.boot_lock_path, resolved.announcement_path].each do |path|
      assert_equal resolved.tmp_root, File.dirname(path), "#{path} is rebuilt by the next boot"
    end
    assert_equal resolved.log_root, File.dirname(resolved.log_path)

    [resolved.connections_root, resolved.connection_pointer_path,
     resolved.binding_path].each do |path|
      assert_equal resolved.root, File.dirname(path), "#{path} cannot be rebuilt"
    end
    assert_equal resolved.connections_root, File.dirname(resolved.pending_connection_path)
    # An MCP OAuth token is a person's consent, so its file is state, not work.
    assert_equal File.join(resolved.root, "mcp", "credentials"), resolved.mcp_credentials_dir
    refute resolved.mcp_credentials_dir.start_with?(resolved.work_root), "a credential never lands in the work root"
  end

  def test_the_identity_root_hangs_off_the_home
    resolved = home

    assert_includes resolved.identity_root("u-1"), resolved.root
  end

  # A public identifier arrives from the wire and becomes a path segment. Any
  # traversal in it would place a credential vault outside the home.
  def test_an_identifier_that_could_escape_the_tree_is_refused
    resolved = home

    ["../elsewhere", "a/b", "", ".", "..", "a\0b"].each do |bad|
      assert_raises(Rho::ConfigurationError) { resolved.identity_root(bad) }
      assert_raises(Rho::ConfigurationError) { resolved.identity_work_root(bad) }
    end
  end

  # ---- privacy ----

  def test_every_directory_it_creates_is_private
    resolved = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(@root, "fresh"))
    resolved.prepare

    [resolved.root, resolved.work_root, resolved.tmp_root, resolved.log_root].each do |path|
      assert_equal 0o700, File.stat(path).mode & 0o777, "#{path} must be private"
    end
  end

  # A narrowing umask turns the requested 0700 into 0500, and a directory rho
  # cannot write into is one it can never place the next level in.
  def test_a_narrowing_umask_still_leaves_usable_private_directories
    previous = File.umask(0o277)
    resolved = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(@root, "fresh"))
    resolved.prepare

    assert_equal 0o700, File.stat(resolved.root).mode & 0o777
    assert_equal 0o700, File.stat(resolved.tmp_root).mode & 0o777
    File.write(File.join(resolved.root, "probe"), "x")
    File.write(File.join(resolved.tmp_root, "probe"), "x")
  ensure
    File.umask(previous) if previous
  end

  # RHO_HOME holds the binding and connection pointer directly now that the
  # per-Nexus layer is gone, so it cannot be a shared
  # parent: StateFile refuses to write into a directory others can read, and a
  # home rho could not write to would be a home that never boots.
  def test_a_pre_existing_root_is_narrowed_because_it_holds_state_directly
    FileUtils.mkdir_p(File.join(@root, "shared"), mode: 0o755)
    File.chmod(0o755, File.join(@root, "shared"))
    resolved = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(@root, "shared"))
    resolved.prepare

    assert_equal 0o700, File.stat(resolved.root).mode & 0o777
    assert_equal 0o700, File.stat(resolved.tmp_root).mode & 0o777
  end

  # Work holds nothing secret, so a shared volume an operator prepared stays
  # as they set it.
  def test_a_pre_existing_work_root_keeps_the_mode_the_operator_gave_it
    shared = File.join(@root, "shared-work")
    FileUtils.mkdir_p(shared, mode: 0o755)
    File.chmod(0o755, shared)
    Rho::Home.resolve(base_url: "https://nexus.example", root: @root, work_root: shared).prepare

    assert_equal 0o755, File.stat(shared).mode & 0o777
  end

  # ---- the roots themselves ----

  # An empty RHO_HOME is unset, not "here". Honouring it literally would put
  # the credential vault in whatever directory the process started in — a
  # separate home per directory, each with its own boot lock — and narrow that
  # directory to 0700 on the way out.
  def test_an_empty_rho_home_is_unset_rather_than_the_working_directory
    previous = ENV["RHO_HOME"]
    ENV["RHO_HOME"] = ""

    resolved = Rho::Home.resolve(base_url: "https://nexus.example")
    assert_equal File.expand_path(Rho::Home::DEFAULT_ROOT), resolved.root
    refute_equal Dir.pwd, resolved.root
  ensure
    ENV["RHO_HOME"] = previous
  end

  def test_an_empty_root_argument_is_refused
    assert_raises(Rho::ConfigurationError) { Rho::Home.resolve(base_url: "https://nexus.example", root: "  ") }
  end

  def test_rho_home_comes_from_the_environment_when_unset
    previous = ENV["RHO_HOME"]
    ENV["RHO_HOME"] = File.join(@root, "custom")

    assert_includes Rho::Home.resolve(base_url: "https://nexus.example").root, "custom"
  ensure
    ENV["RHO_HOME"] = previous
  end

  # ---- work ----

  # State and work are separate trees so an operator can put the churny half on
  # another volume, wipe it, or keep it out of backups without endangering a
  # connection. A plain install still stays one directory.
  def test_work_defaults_inside_the_state_root
    assert_equal File.join(@root, "work"), home.work_root
  end

  def test_the_work_root_can_be_moved_off_the_state_root
    previous = ENV["RHO_WORK_DIR"]
    ENV["RHO_WORK_DIR"] = File.join(@root, "elsewhere")

    assert_equal File.join(@root, "elsewhere"), home.work_root
  ensure
    ENV["RHO_WORK_DIR"] = previous
  end

  def test_an_explicit_work_root_wins_over_the_environment
    previous = ENV["RHO_WORK_DIR"]
    ENV["RHO_WORK_DIR"] = File.join(@root, "from-env")

    resolved = Rho::Home.resolve(
      base_url: "https://nexus.example", root: @root, work_root: File.join(@root, "explicit")
    )
    assert_equal File.join(@root, "explicit"), resolved.work_root
  ensure
    ENV["RHO_WORK_DIR"] = previous
  end

  # Same lesson as RHO_HOME: an empty value is unset, not "here".
  def test_an_empty_work_dir_is_unset_rather_than_the_working_directory
    previous = ENV["RHO_WORK_DIR"]
    ENV["RHO_WORK_DIR"] = ""

    assert_equal File.join(@root, "work"), home.work_root
    refute_equal Dir.pwd, home.work_root
  ensure
    ENV["RHO_WORK_DIR"] = previous
  end

  # Boot proves it can write where it will need to, rather than discovering an
  # unwritable volume hours later in the middle of a task.
  def test_prepare_creates_both_trees_privately
    resolved = Rho::Home.resolve(
      base_url: "https://nexus.example", root: File.join(@root, "state"), work_root: File.join(@root, "w")
    )
    resolved.prepare

    [resolved.root, resolved.work_root].each do |path|
      assert_equal 0o700, File.stat(path).mode & 0o777, "#{path} must be private"
    end
    File.write(File.join(resolved.work_root, "probe"), "x")
  end

  # ---- the instance id ----

  # THE PER-HOME INSTANCE PART of every identifier this home presents,
  # derived at the first `prepare` and never typed: eight lowercase hex
  # characters in a private `instance.json`, kept by every later prepare
  # (identity = the home: an upgrade replaces the checkout, a rollback
  # restarts the old one, and neither re-pairs), nil before the first.
  def test_the_first_prepare_derives_an_instance_id_and_every_later_one_keeps_it
    resolved = home
    assert_nil resolved.instance_id, "no id until the home is prepared"

    resolved.prepare
    id = resolved.instance_id
    assert_match(/\A[0-9a-f]{8}\z/, id)
    assert_equal File.join(@root, "instance.json"), resolved.instance_path
    assert_equal 0o600, File.stat(resolved.instance_path).mode & 0o777
    assert_equal({ "version" => Rho::Home::INSTANCE_VERSION, "id" => id }, JSON.parse(File.read(resolved.instance_path)))

    assert_equal id, home.prepare.instance_id, "a second prepare keeps the id"
    refute_equal id, home(root: Dir.mktmpdir("rho-home-other")).prepare.instance_id, "two homes, two ids"
  end

  # A COPIED HOME IS A FENCED TWIN: the copy answers the original's id, so
  # its pairing takes the original's row under the steward — which is why
  # a home is never copied (README).
  def test_a_copied_home_answers_the_same_id_so_its_pairing_would_fence_the_original
    id = home.prepare.instance_id
    copy = Dir.mktmpdir("rho-home-copy")
    FileUtils.rm_rf(copy)
    FileUtils.cp_r(@root, copy)

    assert_equal id, home(root: copy).instance_id
  ensure
    FileUtils.remove_entry(copy) if copy && File.directory?(copy)
  end

  def test_a_corrupt_instance_file_is_refused_naming_the_path
    resolved = home.prepare
    File.write(resolved.instance_path, "{\"version\": 1}")

    error = assert_raises(Rho::StateError) { resolved.instance_id }
    assert_includes error.message, resolved.instance_path
    File.write(resolved.instance_path, "not json")
    assert_raises(Rho::StateError) { resolved.instance_id }
  end

  def test_identity_work_roots_hang_off_the_work_tree
    resolved = home

    assert_includes resolved.identity_work_root("u-1"), resolved.work_root
  end

  # ---- the settings the person writes (correction (f)) ----

  # The private settings writer preserves unrelated keys. Public clients
  # reach it through Core's daemon or offline settings owner.
  def test_write_setting_merges_one_key_atomically_and_nil_deletes_it
    resolved = home.prepare
    File.write(resolved.settings_path, JSON.generate("default_model" => "m/x", "runner" => "0199-old"), mode: "w", perm: 0o600)

    resolved.write_setting("runner", "0199-h")

    assert_equal({ "default_model" => "m/x", "runner" => "0199-h" }, JSON.parse(File.read(resolved.settings_path)))
    assert_equal 0o600, File.stat(resolved.settings_path).mode & 0o777
    assert_empty Dir.glob(File.join(resolved.root, "settings.json.*")), "no temp file left behind"
    assert_equal "0199-h", resolved.settings_runner

    resolved.write_setting("runner", nil)
    assert_equal({ "default_model" => "m/x" }, JSON.parse(File.read(resolved.settings_path)))
    assert_nil resolved.settings_runner
  end

  def test_write_setting_creates_the_file_when_none_stands_and_refuses_a_broken_one
    resolved = home.prepare
    assert_nil resolved.settings_runner

    resolved.write_setting("runner", "0199-h")
    assert_equal({ "runner" => "0199-h" }, JSON.parse(File.read(resolved.settings_path)))

    File.write(resolved.settings_path, "{ not json")
    assert_raises(Rho::ConfigurationError) { resolved.write_setting("runner", "0199-k") }
    assert_raises(Rho::ConfigurationError) { resolved.settings_runner }
  end
  def test_current_settings_with_widened_permissions_are_refused_without_repair
    resolved = home.prepare
    document = { "settings_version" => 1, "plugins" => {
      "rho.ingress_telegram" => { "configuration" => { "token" => "synthetic-secret" } },
    } }
    resolved.write_settings(document)
    File.chmod(0o644, resolved.settings_path)
    assert_raises(Rho::StateError) { Rho::Config.load(resolved.settings_path, home: resolved) }
    assert_raises(Rho::StateError) { resolved.write_settings(document.merge("default_model" => "changed")) }
    assert_raises(Rho::StateError) { Rho::Settings.prepare(resolved) }
    assert_equal 0o644, File.stat(resolved.settings_path).mode & 0o777
    assert_equal document, JSON.parse(File.read(resolved.settings_path))
  end
end
