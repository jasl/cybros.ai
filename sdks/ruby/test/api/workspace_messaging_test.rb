require "test_helper"

class ApiWorkspaceMessagingTest < Minitest::Test
  WORKSPACE_ID = "019f0000-0000-7000-8000-000000000101".freeze
  SENDER_ID = "019f0000-0000-7000-8000-000000000301".freeze
  RECIPIENT_ID = "019f0000-0000-7000-8000-000000000302".freeze
  PATH = "/agent_api/v1/workspaces/#{WORKSPACE_ID}/messaging".freeze

  def test_read_returns_the_policy_and_workspace_version
    policy = workspace([[200, {}, response]]).messaging

    assert_equal :get, request.fetch(:method)
    assert_equal PATH, request.fetch(:path)
    assert_nil request.fetch(:body)
    assert_instance_of CybrosAgent::Api::WorkspaceMessaging, policy
    assert_equal 7, policy.lock_version
    agent = policy.agents.fetch(0)
    assert_instance_of CybrosAgent::Api::AgentMessaging, agent
    assert_equal RECIPIENT_ID, agent.agent_public_id
    assert_equal "private", agent.mode
    assert_equal [SENDER_ID], agent.allowed_sender_public_ids
  end

  def test_replace_sends_the_complete_policy_with_the_observed_version
    agents = response.fetch("messaging").fetch("agents")
    policy = workspace([[200, {}, response(version: 8)]]).set_messaging(
      agents: agents, lock_version: 7
    )

    assert_equal :put, request.fetch(:method)
    assert_equal PATH, request.fetch(:path)
    assert_equal response, request.fetch(:body)
    assert_equal 8, policy.lock_version
    assert_equal [SENDER_ID], policy.agents.fetch(0).allowed_sender_public_ids
  end

  def test_an_empty_replacement_restores_every_agent_to_public
    policy = workspace([[200, {}, response(agents: [], version: 8)]]).set_messaging(
      agents: [], lock_version: 7
    )

    assert_equal response(agents: []), request.fetch(:body)
    assert_empty policy.agents
  end

  def test_replace_accepts_symbol_keys_in_agent_settings
    agents = [{ agent_public_id: RECIPIENT_ID, mode: "private", allowed_sender_public_ids: [SENDER_ID] }]
    policy = workspace([[200, {}, response(version: 8)]]).set_messaging(
      agents: agents, lock_version: 7
    )

    assert_equal response, JSON.parse(JSON.generate(request.fetch(:body)))
    assert_equal 8, policy.lock_version
    assert_equal [SENDER_ID], policy.agents.fetch(0).allowed_sender_public_ids
  end

  def test_a_private_agent_with_no_allowed_senders_is_preserved
    agents = [{ "agent_public_id" => RECIPIENT_ID, "mode" => "private", "allowed_sender_public_ids" => [] }]
    policy = workspace([[200, {}, response(agents: agents)]]).messaging

    assert_equal 1, policy.agents.length
    assert_equal RECIPIENT_ID, policy.agents.fetch(0).agent_public_id
    assert_equal "private", policy.agents.fetch(0).mode
    assert_empty policy.agents.fetch(0).allowed_sender_public_ids
  end

  def test_public_mode_preserves_the_saved_sender_list
    agents = [{ "agent_public_id" => RECIPIENT_ID, "mode" => "public", "allowed_sender_public_ids" => [SENDER_ID] }]
    policy = workspace([[200, {}, response(agents: agents, version: 8)]]).set_messaging(
      agents: agents, lock_version: 7
    )

    assert_equal response(agents: agents), request.fetch(:body)
    assert_equal "public", policy.agents.fetch(0).mode
    assert_equal [SENDER_ID], policy.agents.fetch(0).allowed_sender_public_ids
  end

  def test_unknown_response_modes_are_carried_without_guessing_a_policy
    agents = [{ "agent_public_id" => RECIPIENT_ID, "mode" => "future", "allowed_sender_public_ids" => [SENDER_ID] }]
    policy = workspace([[200, {}, response(agents: agents)]]).messaging

    assert_equal "future", policy.agents.fetch(0).mode
    assert_equal [SENDER_ID], policy.agents.fetch(0).allowed_sender_public_ids
  end

  def test_owner_refusal_and_stale_version_are_not_retried
    {
      [403, "not_workspace_owner"] => CybrosAgent::Api::Forbidden,
      [409, "stale_object"] => CybrosAgent::Api::Conflict,
    }.each do |(status, code), error_class|
      context = workspace([[status, {}, { "error" => { "code" => code, "message" => "refused" } }]])
      error = assert_raises(error_class) { context.set_messaging(agents: [], lock_version: 7) }

      assert_equal code, error.code
      assert_equal 1, @transport.requests.length
    end
  end

  def test_a_success_missing_policy_fields_is_malformed
    [
      { "messaging" => { "lock_version" => 7 } },
      { "messaging" => { "agents" => [] } },
      response(agents: [{ "agent_public_id" => RECIPIENT_ID, "mode" => "private" }]),
      response(agents: [{ "agent_public_id" => RECIPIENT_ID, "allowed_sender_public_ids" => [] }]),
      response(agents: [{ "mode" => "private", "allowed_sender_public_ids" => [] }]),
    ].each do |body|
      context = workspace([[200, {}, body]])

      assert_raises(CybrosAgent::Api::MalformedResponse) { context.messaging }
    end
  end

  private

    def workspace(script)
      @transport = CybrosAgentTest::FakeTransport.new(script)
      CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: @transport)
        .workspace(WORKSPACE_ID)
    end

    def request
      assert_equal 1, @transport.requests.length
      @transport.requests.fetch(0)
    end

    def response(agents: nil, version: 7)
      {
        "messaging" => {
          "agents" => agents || [
            { "agent_public_id" => RECIPIENT_ID, "mode" => "private", "allowed_sender_public_ids" => [SENDER_ID] },
          ],
          "lock_version" => version,
        },
      }
    end
end
