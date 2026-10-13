require "test_helper"

class AgentAPI::V1::MemoryEditAndGrepTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @secret = create_access_token_fixture(user: @human, name: "Memory editor").secret
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  test "each memory door searches and conditionally edits its own documents" do
    doors.each do |base, scope|
      path = "#{scope}/notes.md"
      document = create_document(base, path, "first\nPLAN\nplan\n")

      post "#{base}/grep", headers: bearer, as: :json,
        params: { memory: { pattern: "plan", path: path, ignore_case: true, limit: 1 } }
      assert_response :success
      assert_equal [{ "path" => path, "line_number" => 2, "text" => "PLAN" }], response.parsed_body.fetch("matches")
      assert response.parsed_body.fetch("truncated")

      fields = edit_fields(document, old_text: "PLAN", new_text: "revised")
      post "#{base}/edit", headers: bearer, as: :json, params: { memory: fields }
      assert_response :success
      assert_equal path, response.parsed_body.dig("memory", "path")
      assert_equal "first\nrevised\nplan\n", response.parsed_body.dig("memory", "content")
      assert_equal document.fetch("lock_version") + 1, response.parsed_body.dig("memory", "lock_version")

      post "#{base}/edit", headers: bearer, as: :json, params: { memory: fields }
      assert_response :conflict
      assert_equal "stale_object", response.parsed_body.dig("error", "code")
    end
  end

  test "edit requires the observed row and refuses missing or ambiguous passages without changing it" do
    base, scope = doors.first
    document = create_document(base, "#{scope}/notes.md", "same same")
    [["", "memory_edit_invalid"], ["absent", "memory_edit_not_found"], ["same", "memory_edit_ambiguous"]].each do |old_text, code|
      assert_no_difference -> { MemoryDocumentVersion.count } do
        post "#{base}/edit", headers: bearer, as: :json,
          params: { memory: edit_fields(document, old_text: old_text, new_text: "changed") }
      end
      assert_response :unprocessable_content
      assert_equal code, response.parsed_body.dig("error", "code")
    end

    post "#{base}/edit", headers: bearer, as: :json,
      params: { memory: { path: document.fetch("path"), old_text: "same same", new_text: "changed" } }
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end

  { "ASCII" => ["ababa", "aba"], "multibyte" => ["雪あいあいあ", "あいあ"] }.each do |kind, (content, old_text)|
    test "edit refuses overlapping #{kind} passages without changing the document" do
      doors.each do |base, scope|
        document = create_document(base, "#{scope}/overlap.md", content)
        stored = MemoryDocument.find_by!(public_id: document.fetch("public_id"))

        assert_no_changes -> { [stored.reload.memory_document_version_id, stored.lock_version,
          stored.content, @conversation.reload.context_revision] } do
          post "#{base}/edit", headers: bearer, as: :json,
            params: { memory: edit_fields(document, old_text: old_text, new_text: "changed") }
          assert_response :unprocessable_content
          assert_equal "memory_edit_ambiguous", response.parsed_body.dig("error", "code")
        end
      end
    end
  end

  test "search refuses an invalid pattern and empty matches stay explicit" do
    doors.each do |base, _scope|
      post "#{base}/grep", headers: bearer, as: :json, params: { memory: { pattern: "[" } }
      assert_response :unprocessable_content
      assert_equal "memory_pattern_invalid", response.parsed_body.dig("error", "code")

      post "#{base}/grep", headers: bearer, as: :json, params: { memory: { pattern: "absent" } }
      assert_response :success
      assert_equal({ "matches" => [], "truncated" => false }, response.parsed_body)
    end
  end

  test "grep rejects invalid and out of range limits at each HTTP door" do
    doors.each do |base, _scope|
      [-1, 0, "abc", 501].each do |limit|
        post "#{base}/grep", headers: bearer, as: :json, params: { memory: { pattern: "x", limit: limit } }
        assert_response :bad_request
        assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
      end
      post "#{base}/grep", headers: bearer, as: :json, params: { memory: { pattern: "x", limit: 500 } }
      assert_response :success
    end
  end

  test "all new memory routes require a member credential" do
    doors.each do |base, _scope|
      %w[grep edit].each do |verb|
        post "#{base}/#{verb}", as: :json, params: { memory: { pattern: "plan" } }
        assert_response :unauthorized
      end
    end
  end

  test "an archived workspace allows grep but refuses edit" do
    base, scope = doors.fetch(1)
    document = create_document(base, "#{scope}/notes.md", "plan")
    @workspace.update!(state: "archived", archived_at: Time.current)

    post "#{base}/grep", headers: bearer, as: :json, params: { memory: { pattern: "plan" } }
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("matches").length

    post "#{base}/edit", headers: bearer, as: :json,
      params: { memory: edit_fields(document, old_text: "plan", new_text: "changed") }
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
  end

  test "editing a skill preserves its description" do
    base, scope = doors.first
    document = create_document(base, "#{scope}/skills/commit-style", "Old instructions", description: "Commit style")
    post "#{base}/edit", headers: bearer, as: :json,
      params: { memory: edit_fields(document, old_text: "Old", new_text: "New") }

    assert_response :success
    assert_equal "New instructions", response.parsed_body.dig("memory", "content")
    assert_equal "Commit style", response.parsed_body.dig("memory", "description")
  end

  private

    def bearer = { "Authorization" => "Bearer #{@secret}" }

    def doors
      workspace = "/agent_api/v1/workspaces/#{@workspace.public_id}"
      [["/agent_api/v1/profile/memory", "user"], ["#{workspace}/memory", "workspace"],
       ["#{workspace}/conversations/#{@conversation.public_id}/memory", "conversation"]]
    end

    def create_document(base, path, content, description: nil)
      post base, headers: bearer, as: :json,
        params: { memory: { path: path, content: content, description: description,
                            expected_public_id: nil, expected_lock_version: nil } }
      assert_response :created
      response.parsed_body.fetch("memory")
    end

    def edit_fields(document, old_text:, new_text:)
      { path: document.fetch("path"), old_text: old_text, new_text: new_text,
        expected_public_id: document.fetch("public_id"), expected_lock_version: document.fetch("lock_version") }
    end
end
