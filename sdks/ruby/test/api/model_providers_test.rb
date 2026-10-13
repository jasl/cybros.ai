require "test_helper"

# A model runs only when its lane is ENABLED and CREDENTIALED, and those
# are independent: somebody who installed a key and never enabled the lane
# has done half the job, and a surface hiding the difference leaves them
# staring at a listing that still says nothing will run.
class ApiModelProvidersTest < Minitest::Test
  LANE = {
    "id" => "openrouter", "display_name" => "OpenRouter", "credentials" => "api_key", "enabled" => true,
    "lock_version" => 3, "configured" => true, "material_kind" => "api_key",
    "reauthorization_required" => false, "models" => 12, "unavailable_until" => nil,
  }.freeze

  def providers(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member",
      transport: @transport).model_providers
  end

  def request = @transport.requests.fetch(0)

  def test_a_lane_is_ready_only_when_both_facts_hold
    lanes = providers([[200, {}, { "model_providers" => [LANE] }]]).list
    lane = lanes.fetch(0)

    assert_equal "/agent_api/v1/model_providers", request.fetch(:path)
    assert_equal "OpenRouter", lane.display_name
    assert_predicate lane, :ready?
    assert_predicate lane, :api_key?
    assert_equal 12, lane.models
  end

  def test_enabled_without_a_credential_is_not_ready
    lane = providers([[200, {}, { "model_providers" => [LANE.merge("configured" => false)] }]])
      .list.fetch(0)

    assert_predicate lane, :enabled?
    refute_predicate lane, :ready?
  end

  def test_a_credential_needing_reauthorization_is_not_ready_either
    lane = providers([[200, {}, {
      "model_providers" => [LANE.merge("reauthorization_required" => true)],
    }]]).list.fetch(0)

    refute_predicate lane, :ready?
  end

  # THE PROVIDER'S OWN CLOCK: the ISO string the kernel holds, nil when
  # clear; always on the wire, so a listing that omits it is malformed.
  # A floored lane is waiting, not off: `ready?` does not read it.
  def test_unavailable_until_is_the_kernels_string_and_never_a_readiness_fact
    lane = providers([[200, {}, {
      "model_providers" => [LANE.merge("unavailable_until" => "2026-09-16T09:00:00Z")],
    }]]).list.fetch(0)

    assert_equal "2026-09-16T09:00:00Z", lane.unavailable_until
    assert_predicate lane, :ready?, "a delay on admission, not a lane that is off"

    assert_nil providers([[200, {}, { "model_providers" => [LANE] }]]).list.fetch(0).unavailable_until
    assert_raises(CybrosAgent::Api::MalformedResponse) do
      providers([[200, {}, { "model_providers" => [LANE.except("unavailable_until")] }]]).list
    end
  end

  def test_the_member_surface_has_no_provider_management_context
    refute_respond_to providers([]), :provider
    assert_empty @transport.requests
  end
end
