require "test_helper"

class CoreMemoryProjectionTest < Minitest::Test
  include RhoTest::CliHarness

  def test_memory_verbs_keep_logical_paths_versions_and_the_saved_workspace
    seen = []
    row = { "path" => "group/notes.md", "public_id" => "memory-1", "lock_version" => 3, "content" => "new fact" }
    matches = { "matches" => [{ "path" => row.fetch("path"), "line_number" => 2, "text" => "new fact" }], "truncated" => true }
    announce(endpoint: recording_routed_endpoint(seen, {
      "GET /conversations/memory" => [[200, { "memory" => [row] }]],
      "POST /conversations/memory/read" => [[200, { "memory" => row }]],
      "POST /conversations/memory/write" => [[201, { "memory" => row }]],
      "POST /conversations/memory/edit" => [[200, { "memory" => row }]],
      "POST /conversations/memory/grep" => [[200, { "result" => matches }]],
      "POST /conversations/memory/delete" => [[200, { "deleted" => { "path" => row.fetch("path") } }]],
    }))

    scope = { workspace_public_id: "ws-original" }
    condition = { expected_public_id: "memory-1", expected_lock_version: 2 }
    assert_equal [row], core.memory_list("chat-1", path: "group/", **scope)
    assert_equal row, core.memory_read("chat-1", path: row.fetch("path"), **scope)
    assert_equal row, core.memory_write("chat-1", path: row.fetch("path"), content: "new fact", **condition, **scope)
    assert_equal row, core.memory_edit("chat-1", path: row.fetch("path"), old_text: "old fact", new_text: "new fact", **condition, **scope)
    assert_equal matches, core.memory_grep("chat-1", pattern: "fact", path: "group/", ignore_case: true, limit: 1, **scope)
    assert_equal({ "path" => row.fetch("path") }, core.memory_delete("chat-1", path: row.fetch("path"), **condition, **scope))

    listing = seen.find { |request| request.start_with?("GET /conversations/memory") }
    assert_equal({ "public_id" => "chat-1", "path" => "group/", "workspace_public_id" => "ws-original" },
      URI.decode_www_form(URI.parse(listing.lines.first.split[1]).query).to_h)
    bodies = seen.grep(%r{\APOST /conversations/memory/}).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal ["ws-original"] * 5, bodies.map { |body| body.fetch("workspace_public_id") }
    assert_equal({ "path" => "group/notes.md", "old_text" => "old fact", "new_text" => "new fact",
      "expected_public_id" => "memory-1", "expected_lock_version" => 2, "public_id" => "chat-1", "workspace_public_id" => "ws-original" }, bodies[2])
    assert_equal({ "pattern" => "fact", "path" => "group/", "ignore_case" => true, "limit" => 1,
      "public_id" => "chat-1", "workspace_public_id" => "ws-original" }, bodies[3])
  end

  def test_reset_and_disabled_bindings_remain_distinct_on_the_control_wire
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /conversations/memory_context" => [[200, { "conversation" => { "public_id" => "chat-1" } }]],
      "POST /conversations/memory/write" => [[201, { "memory" => { "path" => "conversation/new.md" } }]],
    }))
    core.bind_memory_context("chat-1", memory_context: nil, workspace_public_id: "ws-original")
    core.bind_memory_context("chat-1", memory_context: { "bindings" => [] }, workspace_public_id: "ws-original")
    core.memory_write("chat-1", path: "conversation/new.md", content: "first", expected_public_id: nil, expected_lock_version: nil)

    bodies = seen.grep(/\APOST /).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal({ "public_id" => "chat-1", "memory_context" => nil, "workspace_public_id" => "ws-original" }, bodies[0])
    assert_equal({ "bindings" => [] }, bodies[1].fetch("memory_context"))
    assert bodies[2].key?("expected_public_id")
    assert bodies[2].key?("expected_lock_version")
    assert_nil bodies[2].fetch("expected_public_id")
    assert_nil bodies[2].fetch("expected_lock_version")
  end

  def test_read_only_and_stale_refusals_remain_typed_without_retrying
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /conversations/memory/edit" => [[403, { "error" => { "code" => "memory_read_only", "message" => "This binding is read-only" } }]],
      "POST /conversations/memory/delete" => [[409, { "error" => { "code" => "stale_object", "message" => "Read the current document" } }]],
    }))
    error = assert_raises(Rho::Core::Refused) do
      core.memory_edit("chat-1", path: "person/notes.md", old_text: "old", new_text: "new", expected_public_id: "memory-1", expected_lock_version: 0)
    end
    assert_equal [403, "memory_read_only"], [error.status, error.code]
    error = assert_raises(Rho::Core::Refused) do
      core.memory_delete("chat-1", path: "group/notes.md", expected_public_id: "memory-1", expected_lock_version: 0)
    end
    assert_equal [409, "stale_object"], [error.status, error.code]
    assert_equal 2, seen.grep(/\APOST /).length
  end
end
