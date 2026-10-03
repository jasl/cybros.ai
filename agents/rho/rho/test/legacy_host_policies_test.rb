require "test_helper"
require "rho/legacy_host_policies"

class LegacyHostPoliciesTest < Minitest::Test
  PROFILE_A = "019f08b0-0000-7000-8000-000000000001".freeze
  PROFILE_B = "019f08b0-0000-7000-8000-000000000002".freeze

  def setup
    @directory = Dir.mktmpdir("rho-host-migration")
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: @directory)
    @path = File.join(@home.tmp_root, "hosts.json")
    @rows = [
      { "host_type" => "conversation", "host_public_id" => "c-1", "workspace" => "ws-1",
        "live" => true, "model" => "dev/mock-text", "compose" => false,
        "notes" => { "rho.until" => { "command" => "make test" } } },
      { "host_type" => "conversation", "host_public_id" => "c-2", "workspace" => "ws-2",
        "live" => false, "notes" => { "rho.side" => { "parent" => "c-1", "last_turn_at" => 123 } } },
      { "host_type" => "agent_loop", "host_public_id" => "al-1", "workspace" => "ws-1", "live" => true },
    ]
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_partial_import_is_claimed_by_one_profile_and_resumes_without_rewriting_the_source
    Rho::StateFile.new(@path).write("hosts" => @rows)
    original = File.binread(@path)
    first = migration(PROFILE_A)
    assert_equal @rows, first.rows
    refute_path_exists @path
    assert_equal original, File.binread(source_path(PROFILE_A))
    assert_equal @rows.first.slice("model", "compose", "notes"), first.policy("c-1")
    assert_nil first.policy("al-1")
    assert_nil first.policy("missing")

    first.complete("c-1")
    assert_equal original, File.binread(source_path(PROFILE_A))
    refute_path_exists imported_path(PROFILE_A)
    assert_empty migration(PROFILE_B).rows

    # A process can die after Nexus committed one row. It reads the same source
    # again, and the caller's existing Nexus document wins over these defaults.
    resumed = migration(PROFILE_A)
    assert_equal @rows, resumed.rows
    resumed.complete("c-2")
    refute_path_exists imported_path(PROFILE_A)
    resumed.complete("c-1")
    assert_equal original, File.binread(imported_path(PROFILE_A))
    refute_path_exists source_path(PROFILE_A)
    resumed.complete("c-1")
    assert_empty migration(PROFILE_A).rows
    assert_empty migration(PROFILE_B).rows
  end

  def test_an_installation_without_legacy_policies_creates_no_local_business_files
    assert_empty migration(PROFILE_A).rows
    assert_nil migration(PROFILE_A).policy("c-1")
    migration(PROFILE_A).complete("c-1")
    assert_empty Dir.children(@directory)
  end

  def test_a_pure_cache_is_left_for_its_owner_without_claiming_or_rewriting_it
    cache = @rows.map { |row| row.except("model", "compose", "notes") }
    Rho::StateFile.new(@path).write("hosts" => cache)
    original = File.binread(@path)
    assert_empty migration(PROFILE_A).rows
    assert_equal original, File.binread(@path)
    refute_path_exists source_path(PROFILE_A)
    refute_path_exists imported_path(PROFILE_A)
  end

  def test_a_standalone_only_legacy_cache_is_read_once_and_retired_without_a_policy_import
    Rho::StateFile.new(@path).write("hosts" => [@rows.last.merge("notes" => {})])
    original = File.binread(@path)
    assert_equal [@rows.last.merge("notes" => {})], migration(PROFILE_A).rows
    assert_equal original, File.binread(imported_path(PROFILE_A))
    refute_path_exists source_path(PROFILE_A)
  end

  def test_corruption_is_reported_before_claiming_the_source
    Rho::StateFile.new(@path).write("hosts" => @rows)
    File.write(@path, "{broken")
    assert_raises(Rho::StateError) { migration(PROFILE_A).rows }
    assert_path_exists @path
    refute_path_exists source_path(PROFILE_A)
  end

  private

    def migration(id) = Rho::LegacyHostPolicies.new(home: @home, user_public_id: id)
    def source_path(id) = File.join(@home.tmp_root, "hosts.#{id}.migrating.json")
    def imported_path(id) = File.join(@home.tmp_root, "hosts.#{id}.imported.json")
end
