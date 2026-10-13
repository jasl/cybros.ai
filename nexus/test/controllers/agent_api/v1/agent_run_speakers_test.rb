require "test_helper"
require "test_helpers/agent_run_api_test_helper"

class AgentAPI::V1::AgentRunSpeakersTest < ActionDispatch::IntegrationTest
  include AgentRunAPITestHelper

  setup do
    @agent = users(:agent)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: @agent.agent_identifier)
    @token = BoundCredential.new(token: connection.access_token, secret: connection.access_secret)
    @speaker = Speaker.register_ingress(user: @agent, channel_key: "bridge", external_id: "owner", display_name: "Owner")
    @seed = { approval_mode: "bypass", steps: [{ model: { key: "seed", model: MODEL, prompt: "recall" } }] }
  end

  test "a controlled ingress Speaker supplies standalone memory while the member retains authority" do
    anchor = Scopes::Anchor.call(path: "speaker/preferences.md", agent: @agent, speaker: @speaker)
    written = MemoryDocuments::Write.call(anchor: anchor, content: "The owner prefers concise replies.", expected: nil)
    assert_predicate written, :written?

    fixture = Nexus::Contract.pack.fetch("runs.json").fetch("valid_ingress_create_request").fetch("run")
    post loops_path, headers: auth("selected-speaker"), as: :json,
      params: { run: fixture.merge("speaker_public_id" => @speaker.public_id) }
    assert_response :created
    agent_run = loop_record(response.parsed_body.dig("run", "public_id"))
    assert_equal @agent, agent_run.creating_user
    assert_equal @agent, agent_run.declaring_profile
    assert_equal @speaker.public_id, speaker_binding(agent_run).speaker_public_id
    messages = agent_run.agent_run_tasks.sole.input_value
    assert_includes messages.flat_map { |message| message.parts.map(&:text) }.join, "The owner prefers concise replies."
  end

  test "omitted and null Speakers retain the creator's member Speaker" do
    member = Speakers::Resolve.member(account: @account, user: @agent)
    [{}, { speaker_public_id: nil }].each do |fields|
      post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: { run: @seed.merge(fields) }
      assert_response :created
      agent_run = loop_record(response.parsed_body.dig("run", "public_id"))
      assert_equal @agent, agent_run.creating_user
      assert_equal member.public_id, speaker_binding(agent_run).speaker_public_id
    end
  end

  test "unknown, member and another Agent's ingress Speakers cannot create work" do
    other_agent = @account.users.create!(kind: :agent, role: :member, display_name: "Other Agent",
      steward: users(:owner), agent_identifier: "other-agent")
    other = Speaker.register_ingress(user: other_agent, channel_key: "other-bridge",
      external_id: "owner", display_name: "Other owner")
    member = Speakers::Resolve.member(account: @account, user: @agent)
    [SecureRandom.uuid_v7, member.public_id, other.public_id].each do |public_id|
      assert_no_difference [-> { AgentRun.count }, -> { AgentRunCreateReceipt.count }] do
        post loops_path, headers: auth(SecureRandom.uuid), as: :json,
          params: { run: @seed.merge(speaker_public_id: public_id) }
      end
      assert_response :forbidden
      assert_equal "not_authorized", response.parsed_body.dig("error", "code")
    end
  end

  test "standalone Speaker selection rejects malformed UUID fields before creating work" do
    [[@speaker.public_id], { "id" => @speaker.public_id }, true, "", "not-a-uuid"].each do |value|
      assert_no_difference [-> { AgentRun.count }, -> { AgentRunCreateReceipt.count }] do
        post loops_path, headers: auth(SecureRandom.uuid), as: :json,
          params: { run: @seed.merge(speaker_public_id: value) }
      end
      assert_response :bad_request
      assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    end
  end

  test "a Human cannot select an Agent's ingress Speaker" do
    @token = create_access_token_fixture(user: @human, name: "Human")
    assert_no_difference -> { AgentRun.count } do
      post loops_path, headers: auth("human-speaker"), as: :json,
        params: { run: @seed.merge(speaker_public_id: @speaker.public_id) }
    end
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
  end

  test "the selected Speaker participates in create replay identity" do
    envelope = @seed.merge(speaker_public_id: @speaker.public_id)
    post loops_path, headers: auth("speaker-replay"), as: :json, params: { run: envelope }
    assert_response :created
    public_id = response.parsed_body.dig("run", "public_id")

    assert_no_difference -> { AgentRun.count } do
      post loops_path, headers: auth("speaker-replay"), as: :json, params: { run: envelope }
    end
    assert_response :success
    assert_equal true, response.parsed_body.fetch("replayed")
    assert_equal public_id, response.parsed_body.dig("run", "public_id")

    assert_no_difference -> { AgentRun.count } do
      post loops_path, headers: auth("speaker-replay"), as: :json,
        params: { run: envelope.merge(speaker_public_id: nil) }
    end
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
    assert_equal @speaker.public_id, speaker_binding(loop_record(public_id)).speaker_public_id
  end

  test "standalone inputs retain controlled ingress attribution and replay identity" do
    public_id = create_loop!
    post "#{loops_path}/#{public_id}/start", headers: auth
    assert_response :success
    frozen_context = loop_record(public_id).memory_context

    %w[steer queue].each do |mode|
      body = { text: "owner follow-up", delivery_mode: mode, speaker_public_id: @speaker.public_id }
      post "#{loops_path}/#{public_id}/inputs", headers: auth("speaker-#{mode}"), as: :json,
        params: { input: body }
      assert_response :accepted
      input = response.parsed_body.fetch("input")
      assert_equal({ "speaker_public_id" => @speaker.public_id, "kind" => "ingress", "display_name" => "Owner" },
        input.fetch("speaker"))
      assert_equal(mode == "steer" ? "steering" : "pending", input.fetch("state"))
      assert_equal @agent, ConversationInput.find_by!(public_id: input.fetch("public_id")).authoring_user

      assert_no_difference -> { ConversationInput.count } do
        post "#{loops_path}/#{public_id}/inputs", headers: auth("speaker-#{mode}"), as: :json,
          params: { input: body }
      end
      assert_response :success
      assert_equal input.fetch("public_id"), response.parsed_body.dig("input", "public_id")

      post "#{loops_path}/#{public_id}/inputs", headers: auth("speaker-#{mode}"), as: :json,
        params: { input: body.except(:speaker_public_id) }
      assert_response :conflict
      assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
    end
    assert_equal frozen_context, loop_record(public_id).memory_context,
      "follow-up attribution does not retarget the execution's captured memory subject"
  end

  test "standalone inputs refuse Speakers the authenticated Agent does not control" do
    public_id = create_loop!
    other_agent = @account.users.create!(kind: :agent, role: :member, display_name: "Other Agent",
      steward: users(:owner), agent_identifier: "other-input-agent")
    other = Speaker.register_ingress(user: other_agent, channel_key: "other-bridge",
      external_id: "owner", display_name: "Other owner")
    member = Speakers::Resolve.member(account: @account, user: @agent)
    [other.public_id, member.public_id, SecureRandom.uuid_v7].each do |speaker_public_id|
      assert_no_difference -> { ConversationInput.count } do
        post "#{loops_path}/#{public_id}/inputs", headers: auth(SecureRandom.uuid), as: :json,
          params: { input: { text: "follow-up", speaker_public_id: speaker_public_id } }
      end
      assert_response :forbidden
      assert_equal "not_authorized", response.parsed_body.dig("error", "code")
    end
  end

  private

    def speaker_binding(agent_run)
      MemoryContext.from_h(agent_run.memory_context).bindings.find { |binding| binding.scope == :speaker }
    end
end
