require "test_helper"

class AgentAPI::V1::Workspaces::Conversations::MemoryContextsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @secret = create_access_token_fixture(user: @human, name: "Memory context").secret
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @shared = Conversation.create!(workspace: @workspace, creating_user: users(:owner))
  end

  def headers = { "Authorization" => "Bearer #{@secret}" }
  def conversations_path = "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations"
  def base = "#{conversations_path}/#{@conversation.public_id}"
  def own = { "name" => "conversation", "scope" => "conversation", "access" => "read_write" }
  def shared(access = "read_write")
    { "name" => "group", "scope" => "conversation", "access" => access,
      "conversation_public_id" => @shared.public_id }
  end
  def configuration(access = "read_write") = { "bindings" => [own, shared(access)] }

  def configure(value)
    post "#{base}/memory_context", headers: headers, as: :json, params: { memory_context: value }
  end

  def write(path, content)
    post "#{base}/memory", headers: headers, as: :json,
      params: { memory: { path: path, content: content, expected_public_id: nil, expected_lock_version: nil } }
  end

  test "create and replace persist logical bindings and null restores defaults" do
    post conversations_path, headers: headers.merge("Idempotency-Key" => "memory-context-create"),
      as: :json, params: { conversation: { memory_context: configuration } }
    assert_response :created
    assert_equal configuration, response.parsed_body.dig("conversation", "memory_context")
    created = Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))
    assert_equal configuration, created.memory_context

    revision = @conversation.context_revision
    configure(configuration)
    assert_response :success
    assert_equal revision + 1, @conversation.reload.context_revision
    configure(configuration)
    assert_response :success
    assert_equal revision + 1, @conversation.reload.context_revision
    configure(nil)
    assert_response :success
    assert_nil @conversation.reload.memory_context
    assert_equal revision + 2, @conversation.context_revision
  end

  test "aliases address existing database rows and round trip through list show grep and edit" do
    configure(configuration)
    assert_response :success
    write("group/notes.md", "shared fact")
    assert_response :created
    document = response.parsed_body.fetch("memory")
    assert_equal "group/notes.md", document.fetch("path")
    assert MemoryDocument.for_conversation(@shared.id).exists?(name: "notes.md")
    refute MemoryDocument.for_conversation(@conversation.id).exists?(name: "notes.md")

    write("conversation/notes.md", "own fact")
    assert_response :created
    get "#{base}/memory", headers: headers
    assert_response :success
    assert_equal %w[conversation/notes.md group/notes.md], response.parsed_body.fetch("memory").map { |entry| entry.fetch("path") }
    post "#{base}/memory/show", headers: headers, as: :json, params: { memory: { path: "group/notes.md" } }
    assert_response :success
    assert_equal "shared fact", response.parsed_body.dig("memory", "content")
    assert_equal "group/notes.md", response.parsed_body.dig("memory", "path")
    post "#{base}/memory/grep", headers: headers, as: :json, params: { memory: { pattern: "fact" } }
    assert_response :success
    assert_equal %w[conversation/notes.md group/notes.md], response.parsed_body.fetch("matches").map { |entry| entry.fetch("path") }
    post "#{base}/memory/edit", headers: headers, as: :json, params: { memory: {
      path: "group/notes.md", old_text: "shared", new_text: "revised",
      expected_public_id: document.fetch("public_id"), expected_lock_version: document.fetch("lock_version"),
    } }
    assert_response :success
    assert_equal "group/notes.md", response.parsed_body.dig("memory", "path")
    assert_equal "revised fact", response.parsed_body.dig("memory", "content")

    text = Conversations::ContextAssembly::MemoryBlock.call(conversation: @conversation.reload, principal: @human).segments.sole.text
    assert_includes text, "## group/notes.md\nrevised fact"
    assert_includes text, "## conversation/notes.md\nown fact"
  end

  test "read bindings refuse write edit and delete while keeping reads" do
    configure(configuration)
    write("group/notes.md", "shared fact")
    document = response.parsed_body.fetch("memory")
    configure(configuration("read"))
    assert_response :success
    write("group/other.md", "cannot write")
    assert_response :forbidden
    assert_equal "memory_read_only", response.parsed_body.dig("error", "code")
    %w[edit delete].each do |verb|
      post "#{base}/memory/#{verb}", headers: headers, as: :json, params: { memory: {
        path: "group/notes.md", old_text: "shared", new_text: "changed",
        expected_public_id: document.fetch("public_id"), expected_lock_version: document.fetch("lock_version"),
      } }
      assert_response :forbidden
    end
    post "#{base}/memory/show", headers: headers, as: :json, params: { memory: { path: "group/notes.md" } }
    assert_response :success
    assert_equal "shared fact", response.parsed_body.dig("memory", "content")
  end

  test "empty bindings disable every root without falling back to the steward" do
    write("user/private.md", "must stay absent")
    assert_response :created
    configure({ "bindings" => [] })
    assert_response :success
    get "#{base}/memory", headers: headers
    assert_equal [], response.parsed_body.fetch("memory")
    write("user/new.md", "unavailable")
    assert_response :unprocessable_entity
    assert_equal "memory_scope_unavailable", response.parsed_body.dig("error", "code")
    assert_predicate Conversations::ContextAssembly::MemoryBlock.call(conversation: @conversation.reload, principal: @human), :empty?
  end

  test "malformed reserved or duplicate paths refuse atomically" do
    [
      { "bindings" => [shared] },
      { "bindings" => [own, own] },
      { "bindings" => [own, shared.merge("name" => "group/nested")] },
      { "bindings" => [own, shared.merge("name" => "user")] },
      { "bindings" => [own.merge("access" => "write")] },
      { "bindings" => [own, shared.merge("conversation_public_id" => "not-a-uuid")] },
    ].each do |invalid|
      configure(invalid)
      assert_response :unprocessable_entity
      assert_nil @conversation.reload.memory_context
    end
  end

  test "shared sources require same workspace and current read or write standing" do
    private_source = Conversation.create!(workspace: workspaces(:personal), creating_user: users(:owner))
    configure({ "bindings" => [own, shared.merge("conversation_public_id" => private_source.public_id)] })
    assert_response :unprocessable_entity
    @shared.update!(access_default: "read")
    configure(configuration)
    assert_response :unprocessable_entity
    configure(configuration("read"))
    assert_response :success
    @shared.update!(access_default: "none")
    post "#{base}/memory/show", headers: headers, as: :json, params: { memory: { path: "group/notes.md" } }
    assert_response :unprocessable_entity
    assert_equal "memory_scope_unavailable", response.parsed_body.dig("error", "code")
    get "#{base}/memory", headers: headers
    assert_response :success
    assert_equal [], response.parsed_body.fetch("memory")
  end

  test "set requires explicit value and host write standing" do
    post "#{base}/memory_context", headers: headers, as: :json, params: {}
    assert_response :bad_request
    @conversation.update!(archived_at: Time.current)
    configure(configuration)
    assert_response :conflict
    write("conversation/notes.md", "not writable")
    assert_response :conflict
    assert_equal "conversation_archived", response.parsed_body.dig("error", "code")
  end
  test "empty named anchors are discoverable to the model with their access mode" do
    configure(configuration("read"))
    block = Conversations::ContextAssembly::MemoryBlock.call(conversation: @conversation.reload, principal: @human)
    assert_equal 0, block.included
    assert_includes block.segments.sole.text, "group/ (read only)"
    assert_includes block.segments.sole.text, "conversation/ (read and write)"
    refute_includes block.segments.sole.text, "user/"
  end
end
