require "test_helper"

class AgentAPI::V1::Workspaces::Conversations::MemorySpeakersTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: @agent.agent_identifier)
    @headers = { "Authorization" => "Bearer #{connection.access_secret}" }
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @agent, answering_user: @agent)
    @speaker = Speaker.register_ingress(user: @agent, channel_key: "telegram", external_id: "alice", display_name: "Alice")
    @other = Speaker.register_ingress(user: @agent, channel_key: "telegram", external_id: "bob", display_name: "Bob")
    [@speaker, @other].each { |speaker| MemoryCollection.default_for(@agent, speaker: speaker) }
    MemoryCollection.default_for(@conversation)
  end

  def base = "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{@conversation.public_id}/memory"
  def selection(speaker = @speaker) = { speaker_public_id: speaker.public_id,
    **memory_collection_condition(conversation: @conversation, path: "speaker/preferences.md", by: @agent, speaker: speaker) }

  test "all management verbs select one request subject without changing shared bindings" do
    post base, headers: @headers, as: :json, params: { memory: {
      **selection, path: "speaker/preferences.md", content: "Alice prefers tea", expected_public_id: nil, expected_lock_version: nil,
    } }
    assert_response :created
    document = response.parsed_body.fetch("memory")
    row = MemoryDocument.find_by!(public_id: document.fetch("public_id"))
    assert_equal [@agent.id, @speaker.id], [row.memory_collection.user_id, row.memory_collection.speaker_id]

    get base, headers: @headers, params: { memory: selection }
    assert_response :success
    assert_equal ["speaker/preferences.md"], response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }
    get base, headers: @headers, params: { memory: selection(@other) }
    assert_response :success
    assert_empty response.parsed_body.fetch("memory")
    get base, headers: @headers
    assert_response :success
    assert_empty response.parsed_body.fetch("memory")

    post "#{base}/show", headers: @headers, as: :json, params: { memory: { **selection, path: "speaker/preferences.md" } }
    assert_response :success
    assert_equal "Alice prefers tea", response.parsed_body.dig("memory", "content")
    post "#{base}/grep", headers: @headers, as: :json, params: { memory: { **selection, pattern: "tea", path: "speaker/" } }
    assert_response :success
    assert_equal "speaker/preferences.md", response.parsed_body.fetch("matches").sole.fetch("path")

    post "#{base}/edit", headers: @headers, as: :json, params: { memory: {
      **selection, path: "speaker/preferences.md", old_text: "tea", new_text: "coffee",
      expected_public_id: row.public_id, expected_lock_version: row.lock_version,
    } }
    assert_response :success
    assert_equal "Alice prefers coffee", response.parsed_body.dig("memory", "content")
    row.reload
    post "#{base}/delete", headers: @headers, as: :json, params: { memory: {
      **selection, path: "speaker/preferences.md", expected_public_id: row.public_id, expected_lock_version: row.lock_version,
    } }
    assert_response :no_content
    assert_not MemoryDocument.exists?(row.id)
    assert_nil @conversation.reload.memory_context
  end

  test "subject selection preserves explicit bindings and the conversation execution limit" do
    @conversation.update!(memory_context: { "bindings" => [
      { "name" => "conversation", "source" => { "scope" => "conversation" }, "access" => "read_write" },
      { "name" => "speaker", "source" => { "scope" => "speaker", "speaker_public_id" => @other.public_id }, "access" => "read_write" },
    ] })
    post base, headers: @headers, as: :json, params: { memory: {
      **selection, path: "speaker/preferences.md", content: "Bob's fixed subject", expected_public_id: nil, expected_lock_version: nil,
    } }
    assert_response :created
    assert_equal @other.id, MemoryDocument.sole.memory_collection.speaker_id

    @conversation = Conversation.create!(workspace: @workspace, creating_user: @agent, answering_user: @agent,
      memory_context: @conversation.memory_context,
      agent_configuration: { memory_context_limit: { "bindings" => [
        { "name" => "conversation", "source" => { "scope" => "conversation" }, "access" => "read_write" },
      ] } })
    post "#{base}/show", headers: @headers, as: :json, params: { memory: { **selection, path: "speaker/preferences.md" } }
    assert_response :unprocessable_content
    assert_equal "memory_scope_unavailable", response.parsed_body.dig("error", "code")
  end

  test "only the acting Agent's existing ingress Speaker can be selected" do
    other_agent = @account.users.create!(kind: :agent, role: :member, display_name: "Other Agent",
      steward: users(:owner), agent_identifier: "other-memory-agent")
    foreign = Speaker.register_ingress(user: other_agent, channel_key: "other-bridge", external_id: "owner", display_name: "Other owner")
    member = Speakers::Resolve.member(account: @account, user: @agent)
    [foreign.public_id, member.public_id, SecureRandom.uuid_v7].each do |public_id|
      get base, headers: @headers, params: { memory: { speaker_public_id: public_id } }
      assert_response :forbidden
      assert_equal "not_authorized", response.parsed_body.dig("error", "code")
    end
    assert_empty MemoryDocument.all
  end

  test "malformed subjects cannot disappear through scalar parameter filtering" do
    [[@speaker.public_id], { id: @speaker.public_id }, "not-a-uuid"].each do |value|
      post "#{base}/show", headers: @headers, as: :json,
        params: { memory: { path: "speaker/preferences.md", speaker_public_id: value } }
      assert_response :bad_request
      assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    end
  end
end
