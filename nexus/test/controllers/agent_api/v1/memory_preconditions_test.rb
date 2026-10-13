require "test_helper"

# The same public condition at all three doors, with paths still selecting
# their scope. Stale mutations cannot allocate content or bump context.
class AgentAPI::V1::MemoryPreconditionsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @headers = { "Authorization" => "Bearer #{create_access_token_fixture(user: @human, name: "Memory").secret}" }
    workspace_path = "/agent_api/v1/workspaces/#{@workspace.public_id}"
    @doors = {
      "/agent_api/v1/profile/memory" => "user/notes.md",
      "#{workspace_path}/memory" => "workspace/notes.md",
      "#{workspace_path}/conversations/#{@conversation.public_id}/memory" => "conversation/notes.md",
    }
  end

  test "create replace delete and recreate enforce the observed identity and version at every door" do
    @doors.each do |door, path|
      write(door, path, content: "initial", expected_public_id: nil, expected_lock_version: nil)
      assert_response :created
      first = response.parsed_body.fetch("memory")
      assert_match(/\A[0-9a-f-]{14}7[0-9a-f-]{21}\z/, first.fetch("public_id"))
      assert_equal 0, first.fetch("lock_version")
      observed = condition(first)

      get door, headers: @headers
      assert_response :success
      assert_equal first.except("content"), response.parsed_body.fetch("memory").find { |row| row.fetch("path") == path }
      post "#{door}/show", headers: @headers, as: :json, params: { memory: { path: path } }
      assert_response :success
      assert_equal first, response.parsed_body.fetch("memory")

      write(door, path, content: "human correction", **observed)
      assert_response :created
      current = response.parsed_body.fetch("memory")
      assert_equal first.fetch("public_id"), current.fetch("public_id")
      assert_equal 1, current.fetch("lock_version")

      assert_unchanged do
        write(door, path, content: "late extraction", **observed)
        assert_stale
        post "#{door}/delete", headers: @headers, as: :json, params: { memory: { path: path, **observed } }
        assert_stale
        write(door, path, content: "another creation", expected_public_id: nil, expected_lock_version: nil)
        assert_stale
      end

      post "#{door}/delete", headers: @headers, as: :json, params: { memory: { path: path, **condition(current) } }
      assert_response :no_content
      assert_unchanged do
        write(door, path, content: "late recreation", **condition(current))
        assert_stale
      end
      write(door, path, content: "new identity", expected_public_id: nil, expected_lock_version: nil)
      assert_response :created
      recreated = response.parsed_body.fetch("memory")
      assert_not_equal first.fetch("public_id"), recreated.fetch("public_id")
      assert_equal first.fetch("lock_version"), recreated.fetch("lock_version")
      assert_unchanged do
        write(door, path, content: "ABA overwrite", **observed)
        assert_stale
        post "#{door}/delete", headers: @headers, as: :json, params: { memory: { path: path, **observed } }
        assert_stale
      end
      post "#{door}/show", headers: @headers, as: :json, params: { memory: { path: path } }
      assert_equal recreated, response.parsed_body.fetch("memory")
    end
  end

  test "every door requires both conditions and rejects malformed or half absent values" do
    valid_id = SecureRandom.uuid_v7
    @doors.each do |door, path|
      [{}, { expected_public_id: nil }, { expected_lock_version: nil }].each do |fields|
        assert_unchanged do
          write(door, path, content: "not accepted", **fields)
          assert_response :bad_request
          assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
        end
      end
      [{ expected_public_id: nil, expected_lock_version: 0 },
        { expected_public_id: valid_id, expected_lock_version: nil },
        { expected_public_id: "bad", expected_lock_version: 0 },
        { expected_public_id: valid_id, expected_lock_version: -1 },
        { expected_public_id: valid_id, expected_lock_version: 1.5 },
        { expected_public_id: valid_id, expected_lock_version: "abc" },
        { expected_public_id: valid_id, expected_lock_version: 2**31 }].each do |fields|
        assert_unchanged do
          write(door, path, content: "not accepted", **fields)
          assert_response :bad_request
          assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
        end
      end
      assert_unchanged do
        post "#{door}/delete", headers: @headers, as: :json,
          params: { memory: { path: path, expected_public_id: nil, expected_lock_version: nil } }
        assert_response :bad_request
        assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
      end
    end
  end

  test "a valid identity never selects a different path or scope" do
    door, path = @doors.first
    write(door, path, content: "private note", expected_public_id: nil, expected_lock_version: nil)
    observed = condition(response.parsed_body.fetch("memory"))
    assert_unchanged do
      @doors.each do |other_door, other_path|
        write(other_door, "#{other_path}.other", content: "not accepted", **observed)
        assert_stale
      end
    end
  end

  private

    def write(door, path, **fields)
      post door, headers: @headers, as: :json, params: { memory: { path: path, **fields } }
    end

    def condition(document)
      { expected_public_id: document.fetch("public_id"), expected_lock_version: document.fetch("lock_version") }
    end

    def assert_stale
      assert_response :conflict
      assert_equal "stale_object", response.parsed_body.dig("error", "code")
    end

    def assert_unchanged(&block)
      assert_no_changes -> { [MemoryDocument.order(:id).map(&:attributes), MemoryDocumentVersion.order(:id).map(&:attributes),
        @conversation.reload.context_revision] }, &block
    end
end
