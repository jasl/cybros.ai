require "support/dev_commands"

class DevCommandsTest
  # ---- the conversation's environment ----

  # `do --dir DIR [--also D]` BINDS the root set: the
  # directory rides as `working_directory` and as the `environment` the
  # daemon validates and records; the answer's environment prints under
  # the ids; without `--dir` nothing is bound and `Dir.pwd` stays
  # descriptive.
  def test_do_dir_binds_the_root_set_and_prints_it
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /conversations" => [[201, { "conversation" => { "public_id" => "c-9" }, "turn" => { "public_id" => "t-9" },
                                        "run" => { "public_id" => "al-9" },
                                        "environment" => { "root" => "/srv/app", "directories" => ["/srv/docs"], "resolved" => true,
                                                           "relayed" => { "runner" => "0199-h", "state" => "confirmed",
                                                                          "booted_at" => "2026-09-17T06:00:00Z", "resolved" => false } } }],
                                 [201, { "conversation" => { "public_id" => "c-10" }, "turn" => { "public_id" => "t-10" },
                                         "run" => { "public_id" => "al-10" } }]]))

    ops(:do, "fix it", model: "dev/mock-text", dir: "/srv/app", also: ["/srv/docs"])

    body = JSON.parse(seen.grep(%r{\APOST /conversations}).first.partition("\r\n\r\n").last)
    assert_equal "/srv/app", body.fetch("working_directory")
    assert_equal({ "root" => "/srv/app", "directories" => ["/srv/docs"] }, body.fetch("environment"))
    assert_includes lines, "environment:  /srv/app (+ /srv/docs)"
    assert_includes lines, "relayed:      0199-h confirmed (booted 2026-09-17T06:00:00Z; the root is not on that host)"

    reset_out
    ops(:do, "fix it", model: "dev/mock-text")
    body = JSON.parse(seen.grep(%r{\APOST /conversations}).last.partition("\r\n\r\n").last)
    refute body.key?("environment"), "no --dir: nothing bound"
    assert_equal Dir.pwd, body.fetch("working_directory"), "descriptive, as before"
    refute_match(/^environment:/, @out.string)
  end

  # `environment ID [DIR] [--also D]… [--clear]`: the record read, the
  # bind under ABSENT-means-keep (a field the verb did not name is not
  # sent), `--clear` the typed null; each printed as its lines.
  def test_environment_reads_binds_keeps_and_clears_the_record
    seen = []
    read = { "environment" => { "root" => "/srv/app", "directories" => [], "anchor" => "c-1", "source" => "conversation",
                                "lock_version" => 2, "updated_at" => "2026-09-17T00:00:01Z", "resolved" => true, "relayed" => nil } }
    bound = { "environment" => { "root" => "/srv/app", "directories" => ["/srv/docs"], "anchor" => "c-1", "source" => "conversation",
                                 "lock_version" => 3, "updated_at" => "2026-09-17T00:00:02Z", "resolved" => true,
                                 "relayed" => { "runner" => "0199-h", "state" => "pending", "booted_at" => nil, "resolved" => nil } } }
    cleared = { "environment" => { "root" => "/home/rho/work", "directories" => [], "anchor" => nil, "source" => "default",
                                   "lock_version" => nil, "updated_at" => nil, "resolved" => true, "relayed" => nil } }
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /conversations/environment" => [[200, read]],
      "POST /conversations/environment" => [[200, bound], [200, bound], [200, cleared],
                                            [422, { "error" => { "code" => "protected_root", "message" => "/rho is under a protected root" } }]]))

    ops(:environment, "c-1")
    assert_equal ["conversation: c-1", "root:         /srv/app", "directories:  none", "anchor:       c-1",
                  "source:       conversation (version 2, written 2026-09-17T00:00:01Z)", "resolved:     yes",
                  "fs:           off"], lines, @out.string
    assert_match(%r{\AGET /conversations/environment\?public_id=c-1 }, seen.grep(%r{\AGET /conversations/environment}).first)

    reset_out
    ops(:environment, "c-1", "/srv/app", also: ["/srv/docs"])
    body = JSON.parse(seen.grep(%r{\APOST /conversations/environment}).last.partition("\r\n\r\n").last)
    assert_equal({ "public_id" => "c-1", "root" => "/srv/app", "directories" => ["/srv/docs"] }, body)
    assert_includes lines, "directories:  /srv/docs"
    assert_includes lines, "relayed:      0199-h pending"

    reset_out
    ops(:environment, "c-1", also: ["/srv/docs"])
    body = JSON.parse(seen.grep(%r{\APOST /conversations/environment}).last.partition("\r\n\r\n").last)
    assert_equal({ "public_id" => "c-1", "directories" => ["/srv/docs"] }, body, "no DIR: the root is kept, not sent")

    reset_out
    ops(:environment, "c-1", clear: true)
    body = JSON.parse(seen.grep(%r{\APOST /conversations/environment}).last.partition("\r\n\r\n").last)
    assert_equal({ "public_id" => "c-1", "root" => nil }, body, "--clear is the typed null")
    assert_includes lines, "source:       default (no record)"

    error = assert_raises(Rho::Error) { ops(:environment, "c-1", "/rho") }
    assert_equal "/rho is under a protected root", error.message
    assert_raises(Rho::Error) { ops(:environment, nil) }
  end

  # `environments`: the live table, one line per followed conversation.
  def test_environments_lists_the_live_table
    announce(endpoint: routed_endpoint(
      "GET /environments" => [[200, { "environments" => [
        { "conversation" => "c-1", "root" => "/srv/app", "directories" => ["/srv/docs"], "anchor" => "c-1",
          "source" => "conversation", "relayed" => nil, "fs" => { "client" => "zed", "read" => true, "write" => false } },
        { "conversation" => "c-2", "root" => "/srv/app", "directories" => [], "anchor" => "c-1", "source" => "parent",
          "relayed" => { "runner" => "0199-h", "state" => "confirmed", "booted_at" => "2026-09-17T06:00:00Z", "resolved" => true },
          "fs" => nil },
      ] }], [200, { "environments" => [] }]]))

    ops(:environments)
    assert_equal ["c-1  /srv/app (+ /srv/docs)  anchor c-1  conversation  fs on (read) zed",
                  "c-2  /srv/app  anchor c-1  parent  relayed 0199-h confirmed  fs off"], lines, @out.string

    reset_out
    ops(:environments)
    assert_equal ["environments: none — no followed conversation has a record"], lines
  end

  # `environment ID --mcp FILE.json` / `--mcp []`: the file's ACP `mcpServers` array rides the
  # door's `mcp:` member EXACTLY as read — the verb shapes nothing, the
  # daemon's registrar judges each entry — the answer's rows print one
  # `mcp:` line each (name, state, a down row's fault after the dash), the
  # literal `[]` is the close (`mcp: []`, no file, no lines printed), and
  # a file that is missing, not JSON, or not an array is the verb's own
  # refusal with a sentence, nothing sent.
  def test_environment_mcp_sends_the_files_entries_prints_the_rows_and_closes_with_the_literal
    seen = []
    entries = [
      { "type" => "http", "name" => "fx", "url" => "http://127.0.0.1:4321/mcp",
        "headers" => [{ "name" => "X-Secret", "value" => "s3cr3t-value" }] },
      { "type" => "sse", "name" => "sx", "url" => "http://127.0.0.1:4321/sse" },
    ]
    base = { "root" => "/srv/app", "directories" => [], "anchor" => "c-1", "source" => "conversation",
             "lock_version" => 0, "updated_at" => "2026-09-17T00:00:01Z", "resolved" => true, "relayed" => nil, "fs" => nil }
    bound = { "environment" => base.merge("mcp" => [
      { "name" => "fx", "state" => "connected", "fault" => nil, "transport" => "http" },
      { "name" => "sx", "state" => "down", "fault" => "transport sse unsupported", "transport" => "sse" },
    ]) }
    closed = { "environment" => base.merge("mcp" => []) }
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /conversations/environment" => [[200, bound], [200, closed],
                                            [422, { "error" => { "code" => "mcp_unavailable",
                                                                 "message" => "no extension serves the editor's MCP servers" } }]]))

    Dir.mktmpdir("rho-dev-mcp") do |dir|
      file = File.join(dir, "servers.json")
      File.write(file, JSON.pretty_generate(entries), encoding: Encoding::UTF_8)

      ops(:environment, "c-1", mcp: file)
      body = JSON.parse(seen.grep(%r{\APOST /conversations/environment}).last.partition("\r\n\r\n").last)
      assert_equal({ "public_id" => "c-1", "mcp" => entries }, body, "the file's array, as read; nothing else sent")
      assert_includes lines, "mcp:          fx  connected"
      assert_includes lines, "mcp:          sx  down — transport sse unsupported"
      assert_operator lines.index("fs:           off"), :<, lines.index("mcp:          fx  connected"), "the rows follow fs:"

      reset_out
      ops(:environment, "c-1", mcp: "[]")
      body = JSON.parse(seen.grep(%r{\APOST /conversations/environment}).last.partition("\r\n\r\n").last)
      assert_equal({ "public_id" => "c-1", "mcp" => [] }, body, "the literal closes: the typed empty set")
      refute_match(/^mcp:/, @out.string, "a closed set prints no row:\n#{@out.string}")

      error = assert_raises(Rho::Error) { ops(:environment, "c-1", mcp: file) }
      assert_equal "no extension serves the editor's MCP servers", error.message

      sent = seen.length
      error = assert_raises(Rho::Error) { ops(:environment, "c-1", mcp: File.join(dir, "absent.json")) }
      assert_match(/\A--mcp .*absent\.json: no such file — /, error.message)
      File.write(File.join(dir, "object.json"), JSON.generate("name" => "fx"), encoding: Encoding::UTF_8)
      error = assert_raises(Rho::Error) { ops(:environment, "c-1", mcp: File.join(dir, "object.json")) }
      assert_match(/\A--mcp .*object\.json: the file must hold a JSON array of mcpServers entries, got hash\z/, error.message)
      File.write(File.join(dir, "broken.json"), "[", encoding: Encoding::UTF_8)
      error = assert_raises(Rho::Error) { ops(:environment, "c-1", mcp: File.join(dir, "broken.json")) }
      assert_match(/\A--mcp .*broken\.json: not JSON — /, error.message)
      assert_equal sent, seen.length, "a refused file sends nothing"
    end
  end

  # `environments` prints each row's servers under its line, the same
  # `mcp:` lines the record read prints.
  def test_environments_prints_the_editors_servers_under_each_row
    announce(endpoint: routed_endpoint(
      "GET /environments" => [[200, { "environments" => [
        { "conversation" => "c-1", "root" => "/srv/app", "directories" => [], "anchor" => "c-1", "source" => "conversation",
          "relayed" => nil, "fs" => nil,
          "mcp" => [{ "name" => "fx", "state" => "connected", "fault" => nil, "transport" => "http" },
                    { "name" => "sx", "state" => "down", "fault" => "transport sse unsupported", "transport" => "sse" }] },
        { "conversation" => "c-2", "root" => "/srv/app", "directories" => [], "anchor" => "c-2", "source" => "conversation",
          "relayed" => nil, "fs" => nil, "mcp" => [] },
      ] }]]))

    ops(:environments)
    assert_equal ["c-1  /srv/app  anchor c-1  conversation  fs off",
                  "mcp:          fx  connected",
                  "mcp:          sx  down — transport sse unsupported",
                  "c-2  /srv/app  anchor c-2  conversation  fs off"], lines, @out.string
  end

  # `port ID --endpoint URL --token TOKEN [--read] [--write] [--client NAME]` /
  # `port ID --clear`: the
  # surface's file-system port registered through the door's `fs:`
  # member — the flags as given, the client's name (this gem's by
  # default), the token on the wire and never on the terminal — and the
  # typed null that clears it; the answer's `fs` prints on/off with the
  # flags.
  def test_port_registers_the_surfaces_port_through_the_doors_fs_member_and_clears_it
    seen = []
    on = { "environment" => { "root" => "/srv/app", "directories" => [], "anchor" => "c-1", "source" => "conversation",
                              "lock_version" => 0, "updated_at" => "2026-09-17T00:00:01Z", "resolved" => true, "relayed" => nil,
                              "fs" => { "client" => "rho-dev", "read" => true, "write" => true } } }
    read_only = { "environment" => on.fetch("environment").merge("fs" => { "client" => "zed", "read" => true, "write" => false }) }
    off = { "environment" => on.fetch("environment").merge("fs" => nil) }
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /conversations/environment" => [[200, on], [200, read_only], [200, off],
                                            [409, { "error" => { "code" => "runner_elsewhere", "message" => "c-1 runs on 0199-h" } }]]))

    # exe/rho refuses `--url` on every verb (reserved for rho's own address), so the flag is `--endpoint`.
    refute_includes self.class.commands.fetch("port").options.keys, :url
    ops(:port, "c-1", endpoint: "http://127.0.0.1:4321", token: "bearer-1", read: true, write: true)
    body = JSON.parse(seen.grep(%r{\APOST /conversations/environment}).last.partition("\r\n\r\n").last)
    assert_equal({ "public_id" => "c-1", "fs" => { "url" => "http://127.0.0.1:4321", "token" => "bearer-1", "read" => true,
                                                    "write" => true, "client" => "rho-dev" } }, body)
    assert_includes lines, "fs:           on — rho-dev (read, write)"
    refute_includes @out.string, "bearer-1", "the token never prints"

    reset_out
    ops(:port, "c-1", endpoint: "http://127.0.0.1:4321", token: "bearer-1", read: true, client: "zed")
    body = JSON.parse(seen.grep(%r{\APOST /conversations/environment}).last.partition("\r\n\r\n").last)
    assert_equal({ "url" => "http://127.0.0.1:4321", "token" => "bearer-1", "read" => true, "write" => false, "client" => "zed" },
      body.fetch("fs"), "a flag not given is false")
    assert_includes lines, "fs:           on — zed (read)"

    reset_out
    ops(:port, "c-1", clear: true)
    body = JSON.parse(seen.grep(%r{\APOST /conversations/environment}).last.partition("\r\n\r\n").last)
    assert_equal({ "public_id" => "c-1", "fs" => nil }, body, "--clear is the typed null")
    assert_includes lines, "fs:           off"

    error = assert_raises(Rho::Error) { ops(:port, "c-1", endpoint: "http://127.0.0.1:4321", token: "b") }
    assert_equal "c-1 runs on 0199-h", error.message
    assert_raises(Rho::Error) { ops(:port, nil, endpoint: "http://127.0.0.1:4321", token: "b") }
    assert_raises(Rho::Error) { ops(:port, "c-1") }
    assert_raises(Rho::Error) { ops(:port, "c-1", endpoint: "http://127.0.0.1:4321") }
  end
end
