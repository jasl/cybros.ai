require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiIngressActorsTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def test_registration_uses_the_member_profile_and_reads_the_same_typed_actor_for_create_and_resolve
    body = CybrosAgentTest::ContractFixtures.pack("profiles.json").fetch("valid_ingress_actor_fixture")
    [201, 200].each do |status|
      @transport = CybrosAgentTest::FakeTransport.new([[status, {}, body]])
      client = CybrosAgent::Client.new(base_url: "http://example.test", credential: "member", transport: @transport)
      actor = client.profile.register_ingress_actor(channel_key: "bridge:123", external_id: "456", display_name: "External Ada")
      assert_equal body.fetch("ingress_actor"), actor.to_h.transform_keys(&:to_s)
      assert_equal "/agent_api/v1/profile/ingress_actors", request.fetch(:path)
      assert_equal :post, request.fetch(:method)
      assert_equal body.fetch("ingress_actor").slice("channel_key", "external_id", "display_name"),
        request.fetch(:body).fetch("ingress_actor")
    end
  end

  def test_input_selector_and_ingress_voice_survive_the_public_input_and_turn_shapes
    fixture = contract.fetch("valid_ingress_input_fixture")
    actor_id = fixture.dig("input", "speaker", "actor_public_id")
    input = chat([[202, {}, fixture]]).inputs.create(text: "hello", kind: "message",
      idempotency_key: "arrival-1", speaker_actor_public_id: actor_id,
      expected_steering_loop_public_id: "loop-1", delivery_mode: "steer").input
    assert_equal actor_id, request.fetch(:body).dig("input", "speaker_actor_public_id")
    assert_equal "loop-1", request.fetch(:body).dig("input", "expected_steering_loop_public_id")
    assert_equal actor_id, input.speaker.actor_public_id
    assert_equal "ingress", input.speaker.kind
    refute_predicate input.speaker, :agent?
    turn = contract.fetch("valid_ingress_turn_fixture")
    page = { "turns" => [turn], "pagination" => { "before_position" => nil, "after_position" => nil } }
    assert_equal input.speaker, chat([[200, {}, page]]).turns.list.items.first.speaker
  end

  def test_guarded_steer_retains_the_selected_execution_on_the_wire_and_read_shape
    fixture = contract.fetch("valid_guarded_input_fixture")
    loop_id = fixture.fetch("input").fetch("expected_steering_loop_public_id")
    input = chat([[202, {}, fixture]]).inputs.create(text: "correct this run", delivery_mode: "steer",
      idempotency_key: "guarded", expected_steering_loop_public_id: loop_id).input
    assert_equal loop_id, request.fetch(:body).dig("input", "expected_steering_loop_public_id")
    assert_equal loop_id, input.expected_steering_loop_public_id
    assert_equal "steering", input.state
  end

  def test_ingress_voice_requires_its_actor_id_and_never_falls_back_to_a_member
    fixture = contract.fetch("valid_ingress_input_fixture")
    malformed = Marshal.load(Marshal.dump(fixture))
    malformed.fetch("input").fetch("speaker").delete("actor_public_id")
    assert_raises(CybrosAgent::Api::MalformedResponse) do
      chat([[202, {}, malformed]]).inputs.create(text: "hello", idempotency_key: "arrival-1")
    end
  end
end
