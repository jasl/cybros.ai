require "test_helper"
require_relative "../support/ops_harness"

class OpsMemoryProjectionTest < Minitest::Test
  include RhoTest::OpsHarness

  class MemoryApi < NexusDoubles::FakeAgentApi
    attr_accessor :refusal
    attr_reader :memory_calls

    def initialize
      super(workspaces: [{ public_id: "ws-original", name: "Original workspace" }])
      @memory_calls = []
      stock_memory("chat", "group/notes.md", "old fact")
      stock_memory("chat", "conversation/task.md", "task note")
    end

    def call(path, **fields)
      @memory_calls << [path, fields.fetch(:method), fields[:body]] if path.include?("/memory")
      super
    end

    def conversation_response(method, path, credential, body, params: nil)
      return super unless credential == NexusDoubles::MEMBER_TOKEN && path.include?("/conversations/chat/memory")
      return @refusal if @refusal

      if path.end_with?("/memory/edit")
        fields = body.fetch("memory")
        return respond(200, { "memory" => memory_row(fields.fetch("path"), fields.fetch("new_text"), nil,
          public_id: fields.fetch("expected_public_id"), lock_version: fields.fetch("expected_lock_version") + 1) })
      end
      if path.end_with?("/memory/grep")
        return respond(200, { "matches" => [{ "path" => "group/notes.md", "line_number" => 2, "text" => "old fact" }], "truncated" => true })
      end
      if path.end_with?("/memory_context")
        return respond(200, { "conversation" => conversation_row("chat").merge("memory_context" => body.fetch("memory_context")) })
      end
      super
    end
  end

  def test_memory_routes_require_bearer_and_a_connected_member_plane
    daemon = boot
    routes = [[:get, "/conversations/memory?public_id=chat"],
      *%w[read write edit delete grep].map { |verb| [:post, "/conversations/memory/#{verb}"] },
      [:post, "/conversations/memory_context"]]
    routes.each do |method, path|
      assert_equal "401", request(daemon, method, path).code
      response = request(daemon, method, path, token: bearer(daemon), body: { public_id: "chat" })
      assert_equal "409", response.code, response.body
      assert_equal "member_plane_unavailable", JSON.parse(response.body).dig("error", "code")
    end
  end

  def test_edit_and_grep_cross_the_real_sdk_with_named_paths_and_explicit_workspace
    api = MemoryApi.new
    daemon = member_ready(boot, api)
    body = { public_id: "chat", workspace_public_id: "ws-original", path: "group/notes.md",
      old_text: "old fact", new_text: "new fact", expected_public_id: "memory-1", expected_lock_version: 2 }
    response = request(daemon, :post, "/conversations/memory/edit", token: bearer(daemon), body: body)
    assert_equal "200", response.code, response.body
    assert_equal ["group/notes.md", "new fact", 3], JSON.parse(response.body).fetch("memory").values_at("path", "content", "lock_version")

    response = request(daemon, :post, "/conversations/memory/grep", token: bearer(daemon),
      body: { public_id: "chat", workspace_public_id: "ws-original", pattern: "fact", path: "group/", ignore_case: true, limit: 1 })
    assert_equal "200", response.code, response.body
    assert_equal({ "matches" => [{ "path" => "group/notes.md", "line_number" => 2, "text" => "old fact" }], "truncated" => true },
      JSON.parse(response.body).fetch("result"))
    assert_equal [
      ["/agent_api/v1/workspaces/ws-original/conversations/chat/memory/edit", :post,
        { "memory" => { "path" => "group/notes.md", "old_text" => "old fact", "new_text" => "new fact", "expected_public_id" => "memory-1", "expected_lock_version" => 2 } }],
      ["/agent_api/v1/workspaces/ws-original/conversations/chat/memory/grep", :post,
        { "memory" => { "pattern" => "fact", "path" => "group/", "ignore_case" => true, "limit" => 1 } }],
    ], api.memory_calls
    assert_empty daemon.lineage.runs
  end

  def test_list_read_create_and_delete_use_database_documents_and_version_conditions
    api = MemoryApi.new
    daemon = member_ready(boot, api)
    response = request(daemon, :get, "/conversations/memory?public_id=chat&path=group%2F", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    assert_equal ["group/notes.md"], JSON.parse(response.body).fetch("memory").map { |row| row.fetch("path") }
    response = request(daemon, :post, "/conversations/memory/read", token: bearer(daemon), body: { public_id: "chat", path: "group/notes.md" })
    assert_equal "old fact", JSON.parse(response.body).dig("memory", "content")

    response = request(daemon, :post, "/conversations/memory/write", token: bearer(daemon),
      body: { public_id: "chat", path: "conversation/new.md", content: "new note", expected_public_id: nil, expected_lock_version: nil })
    assert_equal "201", response.code, response.body
    row = JSON.parse(response.body).fetch("memory")
    response = request(daemon, :post, "/conversations/memory/delete", token: bearer(daemon),
      body: { public_id: "chat", path: row.fetch("path"), expected_public_id: row.fetch("public_id"), expected_lock_version: row.fetch("lock_version") })
    assert_equal "200", response.code, response.body
    assert_equal({ "path" => "conversation/new.md" }, JSON.parse(response.body).fetch("deleted"))
    response = request(daemon, :post, "/conversations/memory/read", token: bearer(daemon), body: { public_id: "chat", path: row.fetch("path") })
    assert_equal "404", response.code, response.body
    assert_equal "memory_not_found", JSON.parse(response.body).dig("error", "code")
  end

  def test_reset_disable_and_missing_bindings_have_distinct_public_behavior
    api = MemoryApi.new
    daemon = member_ready(boot, api)
    [nil, { "bindings" => [] }].each do |configuration|
      response = request(daemon, :post, "/conversations/memory_context", token: bearer(daemon),
        body: { public_id: "chat", memory_context: configuration })
      assert_equal "200", response.code, response.body
      assert_equal({ "memory_context" => configuration }, api.memory_calls.last.fetch(2))
      projected = JSON.parse(response.body).fetch("conversation")["memory_context"]
      configuration ? assert_equal(configuration, projected) : assert_nil(projected)
    end
    response = request(daemon, :post, "/conversations/memory_context", token: bearer(daemon), body: { public_id: "chat" })
    assert_equal "400", response.code, response.body
    assert_equal 2, api.memory_calls.length
  end

  def test_a_stale_or_read_only_mutation_is_forwarded_once_and_never_repaired
    api = MemoryApi.new
    daemon = member_ready(boot, api)
    [[403, "memory_read_only"], [409, "stale_object"]].each do |status, code|
      api.refusal = CybrosAgent::Response.new(status: status, headers: {}, body: { "error" => { "code" => code, "message" => code } })
      response = request(daemon, :post, "/conversations/memory/edit", token: bearer(daemon), body: {
        public_id: "chat", path: "group/notes.md", old_text: "old", new_text: "new", expected_public_id: "memory-1", expected_lock_version: 0,
      })
      assert_equal status.to_s, response.code, response.body
      assert_equal code, JSON.parse(response.body).dig("error", "code")
    end
    assert_equal 2, api.memory_calls.length
  end
end
