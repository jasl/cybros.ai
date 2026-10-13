require "test_helper"

class CoreRunsTest < Minitest::Test
  include RhoTest::CliHarness

  def test_explicit_follower_lookup_finds_a_side_by_host_or_run_without_listing_it_as_ordinary
    seen = []
    ordinary = { "public_id" => "c-parent", "run_public_ids" => ["parent-run"] }
    side = { "public_id" => "c-side", "run_public_ids" => %w[side-old side-current] }
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /followers " => [[200, { "followers" => [ordinary] }]],
      "GET /followers?side=1 " => [[200, { "followers" => [side] }]]))

    assert_equal [ordinary], core.followers
    assert_equal ordinary, core.follower_row("parent-run")
    assert_empty seen.grep(%r{\AGET /followers\?side=1 }), "an ordinary match needs no Side listing"
    assert_equal side, core.follower_row("c-side")
    assert_equal side, core.follower_row("side-old")
    assert_equal side, core.follower_row("side-current")
    error = assert_raises(Rho::Error) { core.follower_row("unknown") }
    assert_equal "this daemon is not following unknown", error.message
  end

  def test_an_array_that_can_be_converted_to_a_hash_is_not_an_inbox_document
    announce(endpoint: routed_endpoint("GET /asks" => [[200, [["asks", []]]]]))

    error = assert_raises(Rho::Error) { core.asks }

    assert_equal "the daemon answered no inbox", error.message
  end
end
