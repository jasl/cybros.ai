require "support/dev_commands"

class DevCommandsTest
  # `rho fetch UPLOAD_ID`: the bytes, whole, to stdout — what a
  # person redirects to a file; a refusal is the daemon's message, and a
  # missing id never reaches the daemon.
  def test_fetch_writes_the_uploads_bytes_to_stdout_whole
    bytes = "\x89PNG\r\n\x1a\n\x00tail".b
    announce(endpoint: serve do |client, request|
      line = request.lines.first.to_s
      if line.start_with?("GET /uploads/bytes?public_id=up-1")
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n" \
          "Content-Length: #{bytes.bytesize}\r\nConnection: close\r\n\r\n#{bytes}")
      elsif line.start_with?("GET /uploads/bytes")
        answer(client, 404, "error" => { "code" => "not_found", "message" => "no such upload" })
      else
        answer(client, 200, "status" => "ok", "version" => Rho::VERSION,
          "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION)
      end
    end)

    assert_equal bytes.bytesize, ops(:fetch, "up-1")
    assert_equal bytes, @out.string.b, "the bytes and nothing else: a person redirects them"

    error = assert_raises(Rho::Error) { ops(:fetch, "up-9") }
    assert_match(/no such upload/, error.message)
    error = assert_raises(Rho::Error) { ops(:fetch) }
    assert_match(/fetch needs UPLOAD_ID/, error.message)
  end

  # `rho fetch ID --thumbnail | --preview`: the named representation
  # by `kind` on the daemon's one route, the same whole output; both flags
  # at once is refused before any request; the kernel's typed refusal is
  # the daemon's message.
  def test_fetch_prints_a_named_representation_under_its_flag
    small = "\x89PNG\r\n\x1a\n\x00small".b
    seen = []
    announce(endpoint: serve do |client, request|
      line = request.lines.first.to_s
      seen << line
      if line.start_with?("GET /uploads/bytes?public_id=up-1&kind=thumbnail")
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n" \
          "Content-Length: #{small.bytesize}\r\nConnection: close\r\n\r\n#{small}")
      elsif line.start_with?("GET /uploads/bytes?public_id=up-2&kind=preview")
        answer(client, 404, "error" => { "code" => "representation_unavailable", "message" => "no preview" })
      else
        answer(client, 200, "status" => "ok", "version" => Rho::VERSION,
          "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION)
      end
    end)

    assert_equal small.bytesize, ops(:fetch, "up-1", thumbnail: true)
    assert_equal small, @out.string.b

    error = assert_raises(Rho::Error) { ops(:fetch, "up-2", preview: true) }
    assert_match(/no preview/, error.message)

    error = assert_raises(Rho::Error) { ops(:fetch, "up-1", thumbnail: true, preview: true) }
    assert_match(/not both/, error.message)
    refute seen.any? { |line| line.include?("public_id=up-1&kind=preview") }, "refused before any request"
  end

  # `rho task` on a decided row: the denial's detail joins the error line
  # (the reason IS the fact a person reads back) and the stage's fact
  # prints — who and when for a `human|agent` grant, the origin alone for
  # one nobody signed; absent on a held row.
  def test_task_prints_the_denials_detail_and_the_fact
    announce(endpoint: routed_endpoint(
      "GET /runs/task?public_id=al-9&task_key=r1t0" => [[200, { "task" => {
        "key" => "r1t0", "kind" => "tool_task", "status" => "failed", "tool_name" => "bash",
        "tool_input" => { "command" => "printf held > held.txt" },
        "error" => { "key" => "approval_denied", "detail" => "use ls" },
        "approval" => { "origin" => "agent", "decided_by" => "0199-agent", "decided_at" => "2026-09-08T12:00:00Z" },
      } }]],
      "GET /runs/task?public_id=al-9&task_key=r1t1" => [[200, { "task" => {
        "key" => "r1t1", "kind" => "tool_task", "status" => "completed", "tool_name" => "ls",
        "approval" => { "origin" => "rule" },
        "title" => "ls .", "metadata" => { "checkpoint" => "c1" }, "output" => "a.rb",
      } }]],
      "GET /runs/task?public_id=al-9&task_key=r1t2" => [[200, { "task" => {
        "key" => "r1t2", "kind" => "tool_task", "status" => "needs_approval", "tool_name" => "bash",
        "tool_input" => { "command" => "rm -rf build" },
      } }]]
    ))

    ops(:task, "al-9", "r1t0")
    assert_match(/^task:\s+r1t0 \(tool_task\) failed$/, @out.string)
    assert_match(/^error:\s+approval_denied — use ls$/, @out.string)
    assert_match(/^approval:\s+agent \(0199-agent\) at 2026-09-08T12:00:00Z$/, @out.string)

    @out.truncate(0)
    @out.rewind
    ops(:task, "al-9", "r1t1")
    assert_match(/^approval:\s+rule$/, @out.string)
    # The UI's two fields print when present: the header as
    # its line, the carrier as JSON, above the output.
    assert_match(/^title:\s+ls \.$/, @out.string)
    assert_match(/^metadata:\s+\{"checkpoint":"c1"\}$/, @out.string)
    assert_match(/^a\.rb$/, @out.string)

    @out.truncate(0)
    @out.rewind
    ops(:task, "al-9", "r1t2")
    assert_match(/^task:\s+r1t2 \(tool_task\) needs_approval$/, @out.string)
    assert_match(/^input:\s+\{"command":"rm -rf build"\}$/, @out.string)
    refute_match(/^approval:/, @out.string, "a held row carries no fact yet")
    refute_match(/^error:/, @out.string)
    refute_match(/^title:|^metadata:/, @out.string, "a row that carries neither prints neither")
  end

  # `rho call_tool RUNNER TOOL [INPUT_JSON]`: the body it posts —
  # the runner, the tool, the parsed input, the clock — and what it prints:
  # the run, the task's lines as `rho task` prints them, then the content:
  # text as itself, a link as its line ending in the id `rho fetch` takes.
  def test_relay_posts_the_request_and_prints_the_task_then_its_content
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /runs/call_tool" => [[200, { "call_tool" => { "public_id" => "al-7", "task" => {
        "key" => "call_tool", "kind" => "tool_task", "status" => "completed", "tool_name" => "capture",
        "tool_input" => { "note" => "one" }, "title" => "capture", "metadata" => { "checkpoint" => { "step" => 1 } },
        "structured_content" => { "applied" => true, "resolved" => false },
        "output" => "echo:capture:{\"note\":\"one\"}",
        "content" => [{ "type" => "text", "text" => "echo:capture:{\"note\":\"one\"}" },
                      { "type" => "resource_link", "uri" => "nexus://uploads/up-1", "name" => "square.png",
                        "mimeType" => "image/png", "size" => 69, "title" => "a red square" }],
      } } }]]))

    row = ops(:call_tool, "0199-runner", "capture", '{"note":"one"}', timeout: 5_000)

    assert_equal "completed", row.fetch("status")
    posted = JSON.parse(seen.find { |req| req.start_with?("POST /runs/call_tool") }.partition("\r\n\r\n").last)
    assert_equal({ "runner_executor_public_id" => "0199-runner", "tool" => "capture", "input" => { "note" => "one" },
                   "timeout_ms" => 5_000 }, posted)
    assert_match(/^run:\s+al-7$/, @out.string)
    assert_match(/^task:\s+call_tool \(tool_task\) completed$/, @out.string)
    assert_match(/^tool:\s+capture$/, @out.string)
    assert_match(/^input:\s+\{"note":"one"\}$/, @out.string)
    assert_match(/^title:\s+capture$/, @out.string)
    assert_match(/^metadata:\s+\{"checkpoint":\{"step":1\}\}$/, @out.string)
    assert_match(/^structure:\s+\{"applied":true,"resolved":false\}$/, @out.string,
      "the structured answer is what `call_tool R environment_bind` reads a binding back as")
    assert_match(/^echo:capture:\{"note":"one"\}$/, @out.string)
    assert_match(%r{^link:\s+square\.png \(image/png, 69 B\) up-1$}, @out.string, @out.string)
  end

  # A request that did not complete prints its error line and FAILS the
  # verb: the status is the answer, and a script reads it as one.
  def test_relay_fails_the_verb_behind_a_request_that_did_not_complete_and_needs_its_words
    announce(endpoint: routed_endpoint(
      "POST /runs/call_tool" => [[200, { "call_tool" => { "public_id" => "al-8", "task" => {
        "key" => "call_tool", "kind" => "tool_task", "status" => "failed", "tool_name" => "bash",
        "tool_input" => { "command" => "rm -rf /" },
        "error" => { "key" => "approval_denied", "detail" => "recursive delete of a root directory" },
      } } }]]
    ))

    error = assert_raises(Rho::Error) { ops(:call_tool, "0199-runner", "bash", '{"command":"rm -rf /"}') }
    assert_match(/the request failed: approval_denied/, error.message)
    assert_match(/^error:\s+approval_denied — recursive delete of a root directory$/, @out.string)

    assert_match(/call_tool needs RUNNER TOOL/, assert_raises(Rho::Error) { ops(:call_tool, "0199-runner") }.message)
    assert_match(/not JSON/, assert_raises(Rho::Error) { ops(:call_tool, "r", "read", "{oops") }.message)
    assert_match(/JSON object/, assert_raises(Rho::Error) { ops(:call_tool, "r", "read", "[1]") }.message)
    assert_match(/positive/, assert_raises(Rho::Error) { ops(:call_tool, "r", "read", "{}", timeout: 0) }.message)
  end
end
