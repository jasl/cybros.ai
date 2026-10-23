require "test_helper"
require "tmpdir"
require "support/journey_groups"

# THE MANIFEST'S RULES, each refused by name. The shipped manifest passes
# every one; each rule is then shown to bite on a manifest that breaks it,
# so a rule that silently stopped checking would fail here, not in a world
# that quietly shared a Human.
class JourneyGroupsTest < Minitest::Test
  GROUPS = E2E::JourneyGroups

  def test_the_shipped_manifest_is_valid
    assert_empty GROUPS.violations
    GROUPS.validate!
  end

  def test_every_listed_file_exists
    problems = GROUPS.violations(groups: { 1 => %w[rho_conversation no_such_journey] })

    assert_includes problems, "no_such_journey is listed but test/no_such_journey_test.rb does not exist"
  end

  def test_no_file_is_listed_twice_across_harness_and_groups
    problems = GROUPS.violations(harness: GROUPS::HARNESS + %w[rho_conversation])

    assert_includes problems, "rho_conversation is listed 2 times"
  end

  def test_an_unlisted_journey_file_is_refused_and_the_non_journey_patterns_are_not
    Dir.mktmpdir do |dir|
      %w[listed_test.rb stray_test.rb live_x_test.rb x_probe_test.rb x_bench_harness_test.rb manual_x_test.rb
         agent_api_load_test.rb]
        .each { |file| File.write(File.join(dir, file), "") }

      problems = GROUPS.violations(harness: %w[listed], groups: {}, test_dir: dir, weights: {}, optional: [])

      # A bench harness suite runs only through HARNESS, so an unlisted one would run in no gate.
      assert_equal ["test/stray_test.rb is in no group and not a harness test",
                    "test/x_bench_harness_test.rb is in no group and not a harness test"], problems
    end
  end

  def test_two_per_test_ceremony_files_never_share_a_group
    problems = GROUPS.violations(groups: { 1 => %w[rho_conversation rho_daemon] })

    assert_includes problems,
      "group 1 holds rho_conversation and rho_daemon; one of #{GROUPS::ONE_PER_GROUP.join("/")} per group"
  end

  def test_a_shared_human_writer_shares_no_group_with_a_reader
    problems = GROUPS.violations(groups: { 1 => %w[compiled_bytes inference_request_workloads] })

    assert_includes problems, "group 1 holds the shared_human writer compiled_bytes beside the reader inference_request_workloads"
    # The two writers together are not a writer-beside-reader pair.
    assert_empty GROUPS.violations(groups: { 1 => %w[compiled_bytes memory_scopes] })
      .grep(/beside the reader/)
  end

  def test_the_serial_list_is_the_union_of_the_groups_and_the_paths_are_test_files
    assert_equal GROUPS::GROUPS.values.sum([]), GROUPS.journeys
    assert_equal GROUPS.journeys.uniq, GROUPS.journeys
    assert_equal ["test/until_test.rb"], GROUPS.paths(%w[until])
  end

  def test_realtime_is_opt_in_and_still_checked_for_duplicates_and_omissions
    assert_empty GROUPS.journeys & GROUPS::REALTIME
    assert_includes GROUPS.violations(harness: GROUPS::HARNESS + ["realtime_signaling"]),
      "realtime_signaling is listed 2 times"
    assert_includes GROUPS.violations(optional: []),
      "test/realtime_signaling_test.rb is in no group and not a harness test"
  end

  def test_local_mcp_selection_and_lifecycle_journeys_share_the_steward_world
    assert_includes GROUPS::GROUPS.fetch(2), "mcp_tools"
    assert_includes GROUPS::GROUPS.fetch(2), "local_mcp_selection"
  end

  def test_every_group_has_a_weight_and_the_spawn_order_is_heaviest_first
    assert_includes GROUPS.violations(groups: { 1 => %w[rho_conversation] }, weights: { 1 => 1, 9 => 1 }),
      "WEIGHTS names [1, 9] but the groups are [1]"
    weights = GROUPS::GROUPS.keys.to_h { |key| [key, 100] }
      .merge(1 => 239, 2 => 210, 3 => 301, 4 => 148, 6 => 180, 7 => 220)
    expected = [3, 1, 7, 2, 6, 4] + (GROUPS::GROUPS.keys - [1, 2, 3, 4, 6, 7]).sort
    assert_equal expected, GROUPS.spawn_order(weights: weights)
    assert_equal GROUPS::GROUPS.keys.sort, GROUPS.spawn_order.sort
  end

  def test_validate_raises_naming_the_problem
    error = assert_raises(ArgumentError) { GROUPS.validate!(groups: { 1 => %w[rho_conversation rho_daemon] }) }

    assert_match(/\Ajourney manifest: /, error.message)
    assert_match(/group 1 holds rho_conversation and rho_daemon/, error.message)
  end
end
