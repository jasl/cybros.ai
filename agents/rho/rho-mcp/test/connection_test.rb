require "test_helper"

# ONE CONNECTION PER SERVER over the fake transport: the calls, the two-axis law, the restart-for-this-call rule with
# the notice line, death under a call, the cancellation bridge and the
# poison rule, one request in flight.
class ConnectionTest < Minitest::Test
  include McpTest::Helpers

  def setup
    @transports = []
    @server = McpTest::FixtureServer.build(hooks: { "exit" => -> { @on_exit&.call } }, documents: McpTest::FixtureServer::DOCUMENTS)
    @held = []
    @spawn_error = nil
    @factory = lambda do |_row, read_timeout:, oauth: nil|
      McpTest::FakeTransport.new(@server, held: @held, input_required: ["asker"]).tap do |transport|
        transport.read_timeout = read_timeout
        transport.spawn_error = @spawn_error
        transport.pid = 4242 + @transports.length
        @transports << transport
      end
    end
    @clock = -> { Time.at(1_800_000_000) }
    @log = []
    logger = Object.new
    log = @log
    %i[debug info warn error].each { |level| logger.define_singleton_method(level) { |event, **f| log << [level, event, f] } }
    @connection = Rho::Mcp::Connection.new(row, log: logger, transport_factory: @factory, clock: @clock,
      redact: Rho::Runner::Redact.new([McpTest::FX_TOKEN]))
  end

  def row(timeout: nil)
    raw = { "transport" => "stdio", "command" => "ruby", "tools" => ["*"], "startup_timeout_ms" => 2000 }
    raw["timeout_ms"] = timeout if timeout
    Rho::Mcp::Settings.parse({ "fx" => raw }, env: {}).fetch(0)
  end

  def transport = @transports.last

  # A cancelled call returns through the runner's checkpoint: the raise is
  # the answer a test reads.
  def checkpointed
    yield
  rescue Rho::Runner::ExecutionContext::Cancelled => error
    error
  end

  def call(raw, args = {}, env: nil)
    @connection.call_tool(raw, args, public_name: "mcp__fx__#{raw}", env: env)
  end

  def test_open_connects_under_the_startup_bound_lists_once_and_clears_the_bound
    @connection.open!
    assert_equal [2.0], transport.read_timeouts_seen, "the bound is the transport's read timeout during connect + list"
    assert_nil transport.read_timeout, "— then cleared, or a long call would time out per frame"
    assert_equal %w[echo lookup hang exit write picture noise refused blank env], @connection.tools.map(&:name)
    assert_predicate @connection, :connected?
    assert_equal ["fx-server", "1.0.0"], [@connection.server_name, @connection.server_version]
    assert_equal "Be kind to the operator.", @connection.instructions
    assert_equal MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION, @connection.protocol_version
    assert_equal 4242, @connection.pid
    assert_nil @connection.down
  end

  def test_a_call_maps_the_result_and_a_tool_error_is_data
    @connection.open!
    echoed = call("echo", { "text" => "hello" })
    assert_equal ["hello", false], [echoed.content, echoed.is_error]
    looked = call("lookup", { "key" => "k1" })
    assert_equal ["record for k1", { "key" => "k1", "hits" => 2 }], [looked.content, looked.structured_content]
    refused = call("refused")
    assert_equal ["no such record", true], [refused.content, refused.is_error]
    assert_equal '{"only":"structure"}', call("noise").content
    request = transport.requests.find { |r| r[:method] == "tools/call" }
    assert_equal({ name: "echo", arguments: { "text" => "hello" } }, request[:params], "the RAW name goes on the wire")
  end

  def test_minus_32602_is_the_models_mistake_and_another_code_is_failed
    @connection.open!
    missing = call("echo", {})
    assert_predicate missing, :is_error, "the gem's server answers a missing argument as a tool error: data"
    assert_equal "Missing required arguments: text", missing.content
    unknown = call("nope", {})
    assert_predicate unknown, :is_error, "-32602: the model self-corrects with the server's words"
    assert_match(/\AThe server refused the call: /, unknown.content)

    @server.define_tool(name: "boom", description: "raise", input_schema: { properties: {} }) { raise "kaboom" }
    error = assert_raises(Rho::Mcp::CallRefused) { call("boom") }
    assert_match(/\Amcp server fx answered mcp__fx__boom with error -32603: /, error.message)
  end

  def test_an_image_is_written_under_the_envs_artifacts_dir
    @connection.open!
    with_tool_env do |env, _root|
      result = call("picture", {}, env: env)
      assert_equal 1, result.files.length
      assert result.files.all? { |path| path.start_with?(File.join(env.artifacts_dir, "mcp", "fx")) }
      assert_includes result.content, "[audio: audio/wav, content discarded]"
    end
  end

  # A CAPTURE IS NAMED BY ITS CONTENT, never by the task that made it: the text names the path, so
  # a name carrying the task's key would make the same picture read as a new result on every call.
  def test_a_repeated_picture_is_one_result_and_one_content_named_file
    @connection.open!
    with_tool_env do |env, _root|
      first, second = %w[r5t0 r6t0].map do |task_key|
        Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new(task_key: task_key)) do
          call("picture", {}, env: env)
        end
      end

      assert_equal first.content, second.content, "the same picture reads as the same result"
      expected = File.join(env.artifacts_dir, "mcp", "fx", "image-#{Digest::SHA256.hexdigest(McpTest::PNG)[0, 16]}.png")
      assert_equal [expected], first.files
      assert_equal [expected], second.files
      assert_equal [File.basename(expected)], Dir.children(File.dirname(expected)), "one file, no temporary left behind"
    end
  end

  def test_death_under_a_call_fails_naming_the_exit_and_the_next_call_restarts_with_the_notice
    @connection.open!
    @on_exit = -> { transport.die!(status: 3, tail: "fixture: leaving now (#{McpTest::FX_TOKEN})\n") }
    error = assert_raises(Rho::Mcp::ServerGone) { call("exit") }
    assert_equal "mcp server fx exited (status 3) during mcp__fx__exit; its stderr ended: fixture: leaving now (•••); " \
                 "the next call restarts it", error.message
    assert_equal 1, transport.closes, "the dead transport is reaped"
    assert_equal "exited (status 3) at #{@clock.call.strftime("%H:%M:%S")}", @connection.down
    refute_predicate @connection, :connected?
    assert_includes @log, [:warn, "mcp.server_exited", { server: "fx", tool: "mcp__fx__exit", exit: "status 3" }]

    dead = transport
    result = call("echo", { "text" => "again" })
    refute_same dead, transport, "a new transport"
    assert_equal 2, @transports.length
    assert_equal "note: mcp server fx had exited (status 3 at #{@clock.call.strftime("%H:%M:%S")}; its stderr ended: " \
                 "fixture: leaving now (•••)) and was restarted for this call; any state it held is gone\nagain", result.content
    assert_nil @connection.down
    assert_equal %w[echo lookup hang exit write picture noise refused blank env], @connection.tools.map(&:name),
      "a restart lists nothing: the announced set is the bind's"
    refute(transport.requests.any? { |r| r[:method] == "tools/list" })
    assert_includes @log, [:info, "mcp.server_restarted", { server: "fx", tool: "mcp__fx__echo", after: :exited }]
  end

  def test_a_server_that_died_between_calls_is_restarted_for_the_next_call
    @connection.open!
    transport.die!(status: 1)
    assert_equal "exited (status 1) at #{@clock.call.strftime("%H:%M:%S")}", @connection.down
    result = call("echo", { "text" => "x" })
    assert_match(/\Anote: mcp server fx had exited \(status 1 at \d\d:\d\d:\d\d\) and was restarted for this call/, result.content)
    assert_equal 2, @transports.length
  end

  def test_a_failed_restart_fails_the_call_naming_both_and_the_next_call_tries_again
    @connection.open!
    transport.die!(status: 1)
    @spawn_error = "Failed to spawn server process: No such file or directory - ruby"
    error = assert_raises(Rho::Mcp::ServerGone) { call("echo", { "text" => "x" }) }
    assert_equal "mcp server fx had exited (status 1 at #{@clock.call.strftime("%H:%M:%S")}); restarting it for mcp__fx__echo " \
                 "failed: could not connect: Failed to spawn server process: No such file or directory - ruby; the next call tries again",
      error.message
    assert_equal "exited (status 1) at #{@clock.call.strftime("%H:%M:%S")}", @connection.down, "no `down` state that needs a boot"
    @spawn_error = nil
    assert_equal "x", call("echo", { "text" => "x" }).content.lines.last.chomp
  end

  def test_a_cancelled_call_sends_the_notification_answers_nothing_and_poisons_the_connection
    @held << "hang"
    @connection.open!
    context = Rho::Runner::ExecutionContext.new(task_key: "t9")
    answer = :unset
    worker = Thread.new { Rho::Runner::ExecutionContext.with(context) { answer = checkpointed { call("hang") } } }
    await { transport.requests.any? { |r| r[:method] == "tools/call" } }
    assert worker.alive?
    context.cancel(:deadline)
    worker.join(5)
    assert_kind_of Rho::Runner::ExecutionContext::Cancelled, answer, "the call returns through the runner's checkpoint"
    assert_equal :deadline, answer.reason, "— by reason, so the task run answers the clamp as data"
    assert_equal 1, transport.closes, "the poison rule: the ladder ran"
    cancelled = transport.notifications.find { |n| n[:method] == "notifications/cancelled" }
    refute_nil cancelled, "the SDK sent notifications/cancelled: #{transport.notifications.inspect}"
    assert_equal "killed after a timed-out call (mcp__fx__hang) at #{@clock.call.strftime("%H:%M:%S")}", @connection.down
    assert_equal :warn, @log.find { |entry| entry[1] == "mcp.server_killed" }&.first

    result = call("echo", { "text" => "back" })
    assert_equal "note: mcp server fx had been stopped after a timed-out call (mcp__fx__hang) and was restarted for this call; " \
                 "any state it held is gone\nback", result.content
    assert_equal 2, @transports.length
  end

  def test_one_request_in_flight_per_connection_and_a_sibling_cancelled_while_waiting_runs_nothing
    @held << "hang"
    @connection.open!
    first = Thread.new { Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) { call("hang") } }
    await { transport.requests.any? { |r| r[:method] == "tools/call" } }
    waiting_context = Rho::Runner::ExecutionContext.new
    second_answer = :unset
    second = Thread.new do
      Rho::Runner::ExecutionContext.with(waiting_context) { second_answer = checkpointed { call("echo", { "text" => "two" }) } }
    end
    sleep 0.2
    assert_equal 1, transport.requests.count { |r| r[:method] == "tools/call" }, "the sibling waits under the mutex"
    waiting_context.cancel(:deadline)
    transport.instance_variable_get(:@wake) << :released
    first.join(5)
    second.join(5)
    assert_kind_of Rho::Runner::ExecutionContext::Cancelled, second_answer, "cancelled while waiting: nothing was sent"
    assert_equal 1, transport.requests.count { |r| r[:method] == "tools/call" }
  end

  def test_open_failure_tears_the_transport_down_and_names_the_reason
    @spawn_error = "Timed out waiting for server response"
    error = assert_raises(Rho::Mcp::Unavailable) { @connection.open! }
    assert_equal "did not answer within 2000 ms", error.message
    assert_equal 1, transport.closes
    @spawn_error = "Failed to spawn server process: No such file or directory - nope"
    error = assert_raises(Rho::Mcp::Unavailable) { @connection.open! }
    assert_equal "could not connect: Failed to spawn server process: No such file or directory - nope", error.message
  end

  # THE DOCUMENTS' LISTS ride the load beside the tools, each only where
  # the capabilities name it; a restart lists nothing.
  def test_open_lists_the_prompts_and_resources_where_the_capabilities_name_them
    @connection.open!
    assert_equal %w[summarize greet Chatty\ Prompt asker], @connection.prompts.map { |p| p["name"] }
    assert_equal %w[readme notes blob logo nodesc], @connection.resources.map { |r| r["name"] }
    assert_equal ["fx://notes/{id}"], @connection.resource_templates.map { |t| t["uriTemplate"] }
    methods = transport.requests.map { |r| r[:method] }
    assert_equal %w[tools/list prompts/list resources/list], methods.first(3), "the three lists at load, once each"

    bare = McpTest::FakeTransport.new(McpTest::FixtureServer.build(tools: %w[echo]))
    bare.define_singleton_method(:server_info) { super().merge("capabilities" => { "tools" => {} }) }
    connection = Rho::Mcp::Connection.new(row, transport_factory: ->(_r, read_timeout:, oauth: nil) { bare })
    connection.open!
    assert_equal [[], []], [connection.prompts, connection.resources]
    assert_equal [], connection.resource_templates
    assert_equal %w[tools/list], bare.requests.map { |r| r[:method] }, "a server without the capability is never asked"
  end

  def test_a_prompt_and_a_resource_load_as_bodies_and_a_vanished_name_is_skill_unknown
    @connection.open!
    prompt = @connection.load_prompt("summarize", name: "fx-summarize")
    assert_equal ["Summarize the notes.\nBe brief.", false], [prompt.content, prompt.is_error]
    request = transport.requests.find { |r| r[:method] == "prompts/get" }
    assert_equal({ name: "summarize" }, request[:params], "no arguments: the RAW name on the wire")
    chatty = @connection.load_prompt("Chatty Prompt", name: "fx-chatty")
    assert_equal "First line.\n\nassistant:\nAn answer.\n\n[image: image/png, content discarded]", chatty.content
    readme = @connection.load_resource("fx://readme", name: "fx-readme")
    assert_equal ["# Readme\n\nRead me.", false], [readme.content, readme.is_error]
    notes = @connection.load_resource("fx://notes", name: "fx-notes")
    assert_equal "note one\nnote two", notes.content, "a listing with no mimeType reads by its contents' text"
    assert_equal({ uri: "fx://readme" }, transport.requests.find { |r| r[:method] == "resources/read" }[:params])

    gone = @connection.load_prompt("vanished", name: "fx-vanished")
    assert_equal ["skill_unknown: fx-vanished", true], [gone.content, gone.is_error]
    gone = @connection.load_resource("fx://vanished", name: "fx-vanished")
    assert_equal ["skill_unknown: fx-vanished", true], [gone.content, gone.is_error]
  end

  def test_a_load_that_asks_for_input_is_skill_unavailable_and_a_capture_lands_under_the_env
    @connection.open!
    asked = @connection.load_prompt("asker", name: "fx-asker")
    assert_equal ["skill_unavailable: fx-asker asks for input this client does not provide", true], [asked.content, asked.is_error]
    with_tool_env do |env, _root|
      logo = @connection.load_resource("fx://logo", name: "fx-logo", env: env)
      path = File.join(env.artifacts_dir, "mcp", "fx", "fx-logo.png")
      assert_equal [path], logo.files
      assert_equal "fx-logo: image/png, #{McpTest::PNG.bytesize} bytes — saved at #{path} and attached", logo.content
    end
  end

  # THE MODEL-READ SURFACE IS REDACTED BY VALUE:
  # a result's text, its structure — every string in it, keys included —
  # and a document's body pass the row's `Redact` before they leave
  # rho-mcp, the same set the sentences, the tail and the log pass
  # through; a server that answers the token it was handed hands the
  # model `•••`.
  def test_a_result_and_a_document_body_carrying_an_expanded_secret_reach_the_model_redacted
    token = McpTest::FX_TOKEN
    @server.define_tool(name: "reveal", description: "Answer the token.", input_schema: { properties: {} }) do
      MCP::Tool::Response.new([{ type: "text", text: "the token is #{token}" }],
        structured_content: { "token" => token, token => ["nested #{token}", 7] })
    end
    @server.define_resource(uri: "fx://secret", name: "secret", description: "Holds the token.", mime_type: "text/plain") do
      [MCP::Resource::TextContents.new(text: "secret=#{token}", uri: "fx://secret", mime_type: "text/plain")]
    end
    @server.define_prompt(name: "leak", description: "Speaks the token.") do |_args, server_context:|
      MCP::Prompt::Result.new(messages: [McpTest::FixtureServer.message("user", McpTest::FixtureServer.text("say #{token}"))])
    end
    @connection.open!

    result = call("reveal")
    assert_equal "the token is •••", result.content
    assert_equal({ "token" => "•••", "•••" => ["nested •••", 7] }, result.structured_content)
    assert_equal "secret=•••", @connection.load_resource("fx://secret", name: "fx-secret").content
    assert_equal "say •••", @connection.load_prompt("leak", name: "fx-leak").content
  end

  def test_structured_only_results_redact_secrets_before_serializing_the_fallback_text
    token = 'fixture-"quoted"-token\\path'
    @server.define_tool(name: "reveal_structure", description: "Answer the token.", input_schema: { properties: {} }) do
      MCP::Tool::Response.new([], structured_content: { "token" => token, token => ["nested #{token}", 7] })
    end
    @connection = Rho::Mcp::Connection.new(row, transport_factory: @factory, clock: @clock,
      redact: Rho::Runner::Redact.new([token]))
    @connection.open!

    result = call("reveal_structure")
    expected = { "token" => "•••", "•••" => ["nested •••", 7] }
    assert_equal expected, result.structured_content
    assert_equal expected, JSON.parse(result.content)
  end

  # A server known dead at load time is restarted for the load, the body opening with the
  # notice (loads and calls use the same reconnect behavior); a restart lists nothing.
  def test_a_load_revives_a_recorded_exit_with_the_notice
    @connection.open!
    transport.die!(status: 1)
    loaded = @connection.load_prompt("summarize", name: "fx-summarize")
    assert_match(/\Anote: mcp server fx had exited \(status 1 at \d\d:\d\d:\d\d\) and was restarted for this call; any state it held is gone\nSummarize the notes\.\nBe brief\.\z/,
      loaded.content)
    assert_equal 2, @transports.length
    assert_equal %w[prompts/get], transport.requests.map { |r| r[:method] }, "a restart lists nothing"
    assert_equal 4, @connection.prompts.length, "the announced set is the bind's"
  end
end
