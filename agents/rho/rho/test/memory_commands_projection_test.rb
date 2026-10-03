require "test_helper"

class MemoryCommandsProjectionTest < Minitest::Test
  include RhoTest::CliHarness

  def test_cli_write_reads_the_current_version_and_does_not_retry_a_conflict
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /conversations/memory/read" => [[200, { "memory" => { "public_id" => "memory-1", "lock_version" => 4 } }]],
      "POST /conversations/memory/write" => [[409, { "error" => { "code" => "stale_object", "message" => "A newer edit exists" } }]],
    }))

    error = assert_raises(Rho::Core::Refused) do
      Rho::Extensions::Ops::Memory.command(cli, ["chat", "write", "group/notes.md", "new fact"], {})
    end
    assert_equal "stale_object", error.code
    posts = seen.grep(/\APOST /)
    assert_equal ["/conversations/memory/read", "/conversations/memory/write"], posts.map { |request| request.lines.first.split[1] }
    body = JSON.parse(posts.last.partition("\r\n\r\n").last)
    assert_equal ["group/notes.md", "new fact", "memory-1", 4], body.values_at("path", "content", "expected_public_id", "expected_lock_version")
    assert_empty @out.string
  end

  def test_only_write_can_create_after_a_missing_document
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /conversations/memory/read" => [[404, { "error" => { "code" => "memory_not_found", "message" => "No document" } }]],
      "POST /conversations/memory/write" => [[201, { "memory" => { "path" => "conversation/new.md" } }]],
    }))
    Rho::Extensions::Ops::Memory.command(cli, ["chat", "write", "conversation/new.md", "first note"], {})
    assert_includes @out.string, "Write completed: conversation/new.md"
    body = JSON.parse(seen.grep(%r{\APOST /conversations/memory/write}).first.partition("\r\n\r\n").last)
    assert_nil body.fetch("expected_public_id")
    assert_nil body.fetch("expected_lock_version")

    ["delete conversation/missing.md", 'edit {"path":"conversation/missing.md","old_text":"old","new_text":"new"}'].each do |text|
      error = assert_raises(Rho::Core::Refused) { Rho::MemoryCommands.execute(core, "chat", Rho::MemoryCommands.parse(text)) }
      assert_equal [404, "memory_not_found"], [error.status, error.code]
    end
    refute seen.any? { |request| request.match?(%r{\APOST /conversations/memory/(?:edit|delete)}) }
  end

  def test_cli_edit_preserves_exact_text_and_delete_uses_the_observed_identity
    seen = []
    row = { "public_id" => "memory-recreated", "lock_version" => 0, "path" => "group/notes.md", "content" => "" }
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /conversations/memory/read" => [[200, { "memory" => row }]],
      "POST /conversations/memory/edit" => [[200, { "memory" => row }]],
      "POST /conversations/memory/delete" => [[200, { "deleted" => { "path" => row.fetch("path") } }]],
    }))
    Rho::Extensions::Ops::Memory.command(cli, ["chat", "edit", JSON.generate(path: row.fetch("path"), old_text: "a\nb", new_text: "")], json: true)
    assert_equal row, JSON.parse(@out.string)
    Rho::MemoryCommands.execute(core, "chat", Rho::MemoryCommands.parse("delete group/notes.md"), workspace_public_id: "ws-original")
    writes = seen.grep(%r{\APOST /conversations/memory/(?:edit|delete)}).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal ["a\nb", ""], writes.first.values_at("old_text", "new_text")
    assert_equal ["memory-recreated", 0, "ws-original"], writes.last.values_at("expected_public_id", "expected_lock_version", "workspace_public_id")
  end

  def test_parse_and_render_keep_search_text_and_truncation_without_a_write
    action = Rho::MemoryCommands.parse("grep a phrase with spaces")
    assert_equal({ pattern: "a phrase with spaces" }, action.fields)
    refute_predicate action, :writing?
    assert_equal "group/notes.md:2: a phrase\nMore matches exist; narrow the pattern.", Rho::MemoryCommands.render(action,
      { "matches" => [{ "path" => "group/notes.md", "line_number" => 2, "text" => "a phrase" }], "truncated" => true })
    assert_equal "No memory documents.", Rho::MemoryCommands.render(Rho::MemoryCommands.parse(""), [])
    ["unknown", "write group/notes.md", "read", "delete", "edit {broken", 'edit {"path":"group/notes.md"}'].each do |text|
      assert_raises(Rho::Error) { Rho::MemoryCommands.parse(text) }
    end
  end

  def test_a_failed_precondition_read_never_turns_into_a_create
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /conversations/memory/read" => [[403, { "error" => { "code" => "not_authorized", "message" => "No write standing" } }]],
    }))
    assert_raises(Rho::Core::Refused) do
      Rho::MemoryCommands.execute(core, "chat", Rho::MemoryCommands.parse("write group/notes.md new fact"))
    end
    assert_equal 1, seen.grep(/\APOST /).length
  end
end
