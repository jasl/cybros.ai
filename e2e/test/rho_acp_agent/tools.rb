class RhoAcpAgentTest
  # (v) THE CALLS' CONTENT: `write` is a `tool_call` of kind `edit` with its location and ONE diff
  # block carrying the new text; `edit` one diff per `edits[]` entry with both texts; `read` kind
  # `read` with its location; `todo_write` kind `think` AND a `plan` whole — the checklist's
  # entries, priority `medium`, rho's statuses. Every call settles `completed` with the output
  # preview.
  def test_acp_agent_a_write_carries_a_diff_an_edit_one_per_entry_and_todo_write_a_plan
    client = ready
    dir = project("calls")
    session = open_session(client, cwd: dir)
    path = File.join(dir, "draft.txt")

    turn = say(client, session, script(
      [write_call(path, "alpha\nbeta\n"), edit_call(path, "beta", "gamma"), read_call(path), todo_call(TODOS)], "did it"
    ))

    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    calls = tool_calls(turn)
    assert_equal %w[write edit read todo_write], calls.map { |call| call.fetch("title").split(" ").first }, calls.inspect
    write, edit, read, todo = calls
    assert_equal Methods::ToolKind::EDIT, write.fetch("kind")
    assert_equal [{ "path" => path }], write.fetch("locations").map { |location| location.slice("path") }
    assert_equal [{ "type" => "diff", "path" => path, "newText" => "alpha\nbeta\n" }], write.fetch("content").map { |block| block.slice("type", "path", "newText") }
    assert_equal Methods::ToolKind::EDIT, edit.fetch("kind")
    assert_equal [{ "type" => "diff", "path" => path, "oldText" => "beta", "newText" => "gamma" }], edit.fetch("content")
    assert_equal Methods::ToolKind::READ, read.fetch("kind")
    assert_equal [{ "path" => path }], read.fetch("locations").map { |location| location.slice("path") }
    assert_equal Methods::ToolKind::THINK, todo.fetch("kind")
    plan = updates_of(turn, Update::PLAN).last
    refute_nil plan, "todo_write mirrors a plan: #{kinds(turn)}"
    assert_equal TODOS.map { |item| { "content" => item.fetch("content"), "priority" => "medium", "status" => item.fetch("status") } }, plan.fetch("entries")
    calls.each { |call| assert_completed_with_preview(last_frame_for(turn, call.fetch("toolCallId"))) }
    assert_equal "alpha\ngamma\n", File.read(path)
    loop_id = loop_and_key(write.fetch("toolCallId")).first
    assert_equal "completed", await_loop_status(loop_id, "completed").fetch("status")
  end

  # (xi) CONTENT BLOCKS: an `image` block rides the queued turn as an attachment — an upload part on
  # the sealed request — and a `resource` block's text and uri, a `resource_link`'s uri, are among
  # the words the round was sent; an `audio` block is -32602.
  def test_acp_agent_an_image_and_a_resource_block_ride_the_sealed_request_and_audio_is_refused
    client = ready
    session = open_session(client)
    marker = "plan-#{SecureRandom.hex(4)}"
    uri = "file:///notes/#{marker}.md"
    link = "file:///notes/other-#{marker}.md"
    blocks = [
      { "type" => Methods::ContentBlock::TEXT, "text" => reply_prompt("saw it", "what is in the picture?") },
      { "type" => Methods::ContentBlock::IMAGE, "data" => Base64.strict_encode64(E2E::RedSquarePng.bytes), "mimeType" => "image/png" },
      { "type" => Methods::ContentBlock::RESOURCE, "resource" => { "uri" => uri, "mimeType" => "text/markdown", "text" => "the plan #{marker}" } },
      { "type" => Methods::ContentBlock::RESOURCE_LINK, "uri" => link, "name" => "other.md" },
    ]

    turn = say(client, session, blocks)
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    loop_id = loop_for_turn(session, turn_id_of(turn))
    await_loop_status(loop_id, "completed")
    request = agent_api("#{loop_path(loop_id)}/tasks/r1/request").fetch("request")
    uploads = upload_ids(request.fetch("entries"))
    assert_equal 1, uploads.length, "the image rides as one upload: #{request.fetch("entries").inspect}"
    words = texts_of(request.fetch("entries")).join("\n")
    assert_includes words, "the plan #{marker}"
    assert_includes words, uri
    assert_includes words, link
    refute_includes words, "data:image", "no data URL leaves the wire"

    error = assert_raises(RemoteError) do
      say(client, session, [{ "type" => Methods::ContentBlock::AUDIO, "data" => Base64.strict_encode64("RIFF"), "mimeType" => "audio/wav" }])
    end
    assert_equal Code::INVALID_PARAMS, error.code, error.message
  end

  # THE FILE-SYSTEM PORT: a client advertising both fs flags is registered on the record at
  # `session/new` (`fs: {client, read, write}`) — the model's `read` of a path whose disk copy
  # differs answers `fs/read_text_file`'s scripted text and never the disk's; a `write` lands in the
  # editor's buffer, never on disk, and says so; an `edit` reads and writes through the port, the
  # disk untouched. A WRITE-ONLY client's `edit` is the disk on both halves (no port request).
  # `session/close` drops the port.
  def test_acp_agent_a_client_with_fs_serves_reads_and_writes_from_its_buffers_and_a_write_only_client_edits_on_disk
    dir = project("port")
    marker = "buffer-#{SecureRandom.hex(4)}"
    buffered = File.join(dir, "buffered.txt")
    File.write(buffered, "the disk copy\n")
    editor = ready(capabilities: E2E::AcpClient.capabilities(read: true, write: true), buffers: { buffered => "#{marker} in the buffer\n" })
    session = open_session(editor, cwd: dir)
    assert_equal({ "client" => E2E::AcpClient::CLIENT_INFO.fetch("name"), "read" => true, "write" => true }, environment_of(session).fetch("fs"))

    turn = say(editor, session, script([read_call(buffered)], "read it"))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    loop_id, key = loop_and_key(tool_calls(turn).first.fetch("toolCallId"))
    await_loop_status(loop_id, "completed")
    shown = task_output(loop_id, key)
    assert_includes shown, "#{marker} in the buffer", "the model's read is the buffer"
    refute_includes shown, "the disk copy", "never the disk"
    read = editor.fs_requests.find { |seen| seen["method"] == Methods::FS_READ_TEXT_FILE }
    refute_nil read, "the surface relayed the read: #{editor.fs_requests.inspect}"
    assert_equal [session, buffered], read.fetch("params").values_at("sessionId", "path")
    assert_kind_of Integer, read.dig("params", "limit"), "a limit always rides the port's read"

    written = File.join(dir, "written.txt")
    turn = say(editor, session, script([write_call(written, "through the port\n")], "wrote it", spent: 1))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    loop_id, key = loop_and_key(tool_calls(turn).first.fetch("toolCallId"))
    await_loop_status(loop_id, "completed")
    assert_equal "through the port\n", editor.buffer(written), "the write landed in the editor's buffer"
    refute_path_exists written, "a buffer-only editor wrote nothing to disk"
    assert_includes task_output(loop_id, key), "written through #{E2E::AcpClient::CLIENT_INFO.fetch("name")}"

    turn = say(editor, session, script([edit_call(buffered, "in the buffer", "edited in the buffer")], "edited it", spent: 2))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    await_loop_status(loop_and_key(tool_calls(turn).first.fetch("toolCallId")).first, "completed")
    assert_equal "#{marker} edited in the buffer\n", editor.buffer(buffered)
    assert_equal "the disk copy\n", File.read(buffered), "an edit through both halves leaves the disk alone"

    assert_equal({}, editor.close_session(session))
    assert_nil environment_of(session)["fs"], "close drops the port"

    other = project("disk")
    on_disk = File.join(other, "draft.txt")
    File.write(on_disk, "alpha\nbeta\n")
    writer = ready(capabilities: E2E::AcpClient.capabilities(write: true))
    session = open_session(writer, cwd: other)
    assert_equal({ "client" => E2E::AcpClient::CLIENT_INFO.fetch("name"), "read" => false, "write" => true }, environment_of(session).fetch("fs"))
    turn = say(writer, session, script([edit_call(on_disk, "beta", "gamma")], "edited on disk"))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    await_loop_status(loop_and_key(tool_calls(turn).first.fetch("toolCallId")).first, "completed")
    assert_equal "alpha\ngamma\n", File.read(on_disk), "one flag: the disk on both halves"
    assert_empty writer.fs_requests, "an edit under one flag asks the port nothing"
  end

  # THE EDITOR'S SERVERS: the ACP `mcpServers` list of `session/new` rides the bind VERBATIM — the
  # mock world's http fixture, one entry with a credential-shaped header — and the fixture's tool
  # runs in THAT session alone: the record lists the row connected, the mock's call is addressed to
  # this daemon's agent slot and answered with the fixture's text, `rho mcp` lists the row with its
  # owner, the header's value never reaches rho.log; a second session without the list calling the
  # name is the kernel's `unknown_tool`. An `sse` entry beside the http row is listed down
  # (`transport sse unsupported`) and `session/new` still answers; a malformed entry is -32602.
  # `session/close` closes the set.
  def test_acp_agent_session_new_with_mcp_servers_runs_the_fixtures_tool_in_that_session_alone
    url = mcp_fixture_url
    secret = E2E::SecretHygiene.register("s3cr3t-#{SecureRandom.hex(8)}")
    entry = { "type" => "http", "name" => "fx", "url" => url, "headers" => [{ "name" => "X-Secret", "value" => secret }] }
    client = ready
    session_a = client.new_session(cwd: project("fx-a"), mcp_servers: [entry]).fetch("sessionId")
    rows = environment_of(session_a).fetch("mcp")
    assert_equal [%w[fx connected]], rows.map { |row| row.values_at("name", "state") }, rows.inspect

    turn = say(client, session_a, script([echo_call("hello from acp")], "echoed"))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    call = tool_calls(turn).first
    assert_equal Methods::ToolKind::OTHER, call.fetch("kind")
    loop_id, key = loop_and_key(call.fetch("toolCallId"))
    await_loop_status(loop_id, "completed")
    task = task_detail(loop_id, key)
    assert_equal %w[mcp__fx__echo completed], task.values_at("tool_name", "status"), task.inspect
    assert_equal "agent_application", task.dig("addressed_to", "role"), "the editor's server runs on this daemon's agent slot"
    assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}hello from acp", task_output(loop_id, key).strip
    listed, status = @daemon.cli("mcp")
    assert_predicate status, :success?, "rho mcp failed:\n#{listed}"
    row = listed.lines.find { |line| line.start_with?("server:") && line.include?("fx") && line.include?(url) }
    refute_nil row, "rho mcp lists the session's server:\n#{listed}"
    assert_includes row, session_a, "with its owner"
    refute_includes listed, secret
    refute_includes @daemon.log_text, secret, "the header's value never reaches rho.log"

    session_b = client.new_session(cwd: project("fx-b")).fetch("sessionId")
    turn = say(client, session_b, script([echo_call("hello from b")], "tried"))
    assert_equal Methods::StopReason::END_TURN, turn.stop_reason
    loop_id, key = loop_and_key(tool_calls(turn).first.fetch("toolCallId"))
    await_loop_status(loop_id, "completed")
    task = task_detail(loop_id, key)
    assert_equal %w[failed unknown_tool], [task.fetch("status"), task.dig("error", "key")], "a's server is not offered to b: #{task.inspect}"

    sse = { "type" => "sse", "name" => "sx", "url" => url, "headers" => [] }
    session_c = client.new_session(cwd: project("fx-c"), mcp_servers: [entry, sse]).fetch("sessionId")
    rows = environment_of(session_c).fetch("mcp")
    assert_equal %w[fx sx], rows.map { |row| row.fetch("name") }, rows.inspect
    down = rows.find { |row| row.fetch("name") == "sx" }
    assert_match(/\Adown/, down.fetch("state"), down.inspect)
    listed, = @daemon.cli("mcp")
    faulted = listed.lines.find { |line| line.start_with?("server:") && line.include?("sx") && line.include?(session_c) }
    refute_nil faulted, "rho mcp lists the faulted row with its owner:\n#{listed}"
    assert_includes faulted, "transport sse unsupported"

    error = assert_raises(RemoteError) { client.new_session(cwd: project("fx-d"), mcp_servers: [{ "name" => "broken" }]) }
    assert_equal Code::INVALID_PARAMS, error.code, error.message

    assert_equal({}, client.close_session(session_a))
    assert_empty environment_of(session_a).fetch("mcp"), "close closes the set"
  end
end
