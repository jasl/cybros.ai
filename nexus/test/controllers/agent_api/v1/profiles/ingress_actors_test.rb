require "test_helper"

class AgentAPI::V1::Profiles::IngressActorsTest < ActionDispatch::IntegrationTest
  setup do
    @agent = users(:agent)
    @secret = connect_agent_session(steward: users(:owner), agent_identifier: @agent.agent_identifier).access_secret
  end

  def register(secret: @secret, **fields)
    post "/agent_api/v1/profile/ingress_actors", as: :json,
      headers: { "Authorization" => "Bearer #{secret}" },
      params: { ingress_actor: { channel_key: "bridge:123", external_id: "456", display_name: "Ada" }.merge(fields) }
  end

  test "registration resolves its immutable natural key without changing or transferring the voice" do
    assert_difference "Actor.count", 1 do
      assert_no_difference ["User.count", "AccessToken.count", "TaskExecutor.count"] do
        register
      end
    end
    assert_response :created
    first = response.parsed_body.fetch("ingress_actor")
    assert_equal %w[channel_key display_name external_id kind public_id], first.keys.sort
    assert_equal "ingress", first.fetch("kind")
    assert Actor.find_by!(public_id: first.fetch("public_id")).ingress_controlled_by?(@agent)

    assert_no_difference "Actor.count" do
      register(display_name: "Changed", ignored: true)
    end
    assert_response :ok
    assert_equal first, response.parsed_body.fetch("ingress_actor")

    other = connect_agent_session(steward: users(:owner), agent_identifier: "bridge.other")
    register(secret: other.access_secret)
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
    assert_equal @agent.id, Actor.find_by!(public_id: first.fetch("public_id")).user_id
  end

  test "only Agent member credentials register and fields stay bounded" do
    register(secret: create_access_token_fixture(user: users(:owner), name: "human").secret)
    assert_response :forbidden
    assert_equal "not_agent_profile", response.parsed_body.dig("error", "code")

    [{ channel_key: "member" }, { channel_key: "system" }, { channel_key: "x" * 65 },
     { external_id: "x" * 129 }, { display_name: "x" * 101 }, { display_name: "" }].each do |bad|
      assert_no_difference "Actor.count" do
        register(**bad)
      end
      assert_response :unprocessable_content
      assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    end
  end
end
