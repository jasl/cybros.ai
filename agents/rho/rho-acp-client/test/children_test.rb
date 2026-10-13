require "test_helper"

# THE CHILDREN TABLE AND THE CALL over the scripted agent: one resident child per (conversation,
# agent) in its own process group, `initialize` once, `session/new` per
# session, `session/prompt` per call; the child's updates into the text
# and the progress tail; the permission call_tool through the floor; cancel
# as a `session/cancel` line inside the grace; the wall killing the group;
# a death answered by name and never revived; release on the
# conversation's end; every line both ways in the capture, redacted.
class ChildrenTest < Minitest::Test
  include RhoAcpClientTest::Helpers

  Recorder = Struct.new(:tails) do
    def tail(text) = tails << text
    def wait(_now = nil) = nil
    def flush(_now = nil) = false
  end

  def setup
    @log_io = StringIO.new
    @log = Rho::Log.new(io: @log_io, level: :debug)
  end

  def teardown = Rho::AcpClient.reset!

  def log_text = @log_io.string

  def host
    Rho::Extensions::Host.new(
      home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(Dir.tmpdir, "rho-acp-children-test")),
      log: @log, clock: -> { Time.now }, config: Rho::Config.from_hash({}), processes: nil
    )
  end

  def load(table)
    Rho::AcpClient.settings_table = table
    result = Rho::Runner::Extensions::Loader.call(gems: ["rho/acp-client"], api_class: Rho::Extensions::Api,
      api_options: { host: host }, log: @log)
    assert_predicate result, :ok?, result.failures.inspect
    result
  end

  def call(args, env)
    Rho::AcpClient.call(args, env: env)
  end

  def sessions = Rho::AcpClient.report.fetch("sessions")

  def trailer(result) = result.content.lines.last.strip

  # ---- the floor turn, the reuse, the session, the workdir ----

  def test_a_plain_delegation_answers_the_text_the_trailer_the_structure_and_the_capture
    load({ "plain" => RhoAcpClientTest.raw_row("plain") })
    with_tool_env(conversation: "conv-1") do |env, root|
      result = call({ "agent" => "plain", "prompt" => "hello from rho" }, env)
      refute_predicate result, :is_error, result.content
      assert_equal "echo: hello from rho", result.content.lines.first.strip
      structure = result.structured_content
      session = structure.fetch("session")
      assert_match(/\Aacp-[0-9a-f]{12}\z/, session)
      assert_equal({ "agent" => "plain", "session" => session, "stopReason" => "end_turn", "calls" => 0, "refused" => 0,
                     "usage" => nil }, structure)
      capture = File.join(env.artifacts_dir, "acp", "plain-#{session}.jsonl")
      assert_equal "session: #{session} · stop: end_turn · calls: 0 (0 refused by the floor) · capture: #{capture}", trailer(result)
      assert_equal [capture], result.files
      assert File.file?(capture), "the capture is written under the root's artifacts"

      lines = capture_lines(capture)
      methods = lines.map { |line| [line.fetch("dir"), line.dig("message", "method")] }
      assert_equal [["note", nil], ["out", "initialize"], ["in", nil]], methods.first(3),
        "the spawn's note, then the handshake, open the capture"
      assert_equal "spawned", lines.fetch(0).fetch("event")
      assert_includes methods, ["out", "session/new"]
      assert_includes methods, ["out", "session/prompt"]
      assert_includes methods, ["in", "session/update"]
      chunk = lines.find { |line| line.dig("message", "params", "update", "sessionUpdate") == "agent_message_chunk" }
      refute_nil chunk, "the child's chunks are captured"
      assert_equal "conv-1", lines.fetch(0).fetch("conversation")

      listed = sessions
      assert_equal 1, listed.length
      row = listed.fetch(0)
      assert_equal %w[plain conv-1], row.values_at("agent", "conversation")
      assert_equal session, row.fetch("session")
      assert_equal root, row.fetch("cwd")
      assert_kind_of Integer, row.fetch("pid")
      assert_kind_of Integer, row.fetch("pgid")
      assert_equal 1, row.fetch("calls")
      assert_equal capture, row.fetch("capture")
      assert process_group_alive?(row.fetch("pgid")), "the child lives on past the call"
      assert_match(/event=acp\.child_spawned agent=plain conversation=conv-1 pid=\d+ pgid=\d+/, log_text)
      assert_match(/event=acp\.session_opened agent=plain conversation=conv-1 session=#{session}/, log_text)
    end
  end

  def test_one_child_per_conversation_and_agent_its_sessions_multiplexed
    load({ "plain" => RhoAcpClientTest.raw_row("plain") })
    with_tool_env(conversation: "conv-1") do |env, root|
      first = call({ "agent" => "plain", "prompt" => "one" }, env).structured_content.fetch("session")
      second = call({ "agent" => "plain", "prompt" => "two" }, env).structured_content.fetch("session")
      refute_equal first, second, "a call without `session` opens a new session"
      pids = sessions.map { |row| row.fetch("pid") }.uniq
      assert_equal 1, pids.length, "one process for the pair: #{sessions.inspect}"

      # `session` continues the same child session: the fixture's own
      # session id is the first it minted (`fx-1`), its cwd the root.
      continued = call({ "agent" => "plain", "prompt" => "session?", "session" => first }, env)
      refute_predicate continued, :is_error, continued.content
      seen = JSON.parse(continued.content.lines.first)
      assert_equal root, seen.fetch("cwd")
      assert_equal 0, seen.fetch("mcpServers"), "rho hands the child no MCP servers"
      assert_equal first, continued.structured_content.fetch("session")
      assert_equal 2, sessions.find { |row| row.fetch("session") == first }.fetch("calls")

      # A different workdir on a reused session is refused by name; a
      # workdir on a NEW session is the session's cwd for its life.
      other = File.join(root, "sub")
      FileUtils.mkdir_p(other)
      refused = call({ "agent" => "plain", "prompt" => "x", "session" => first, "workdir" => "sub" }, env)
      assert_predicate refused, :is_error
      assert_equal "session #{first} works in #{root}; a session's workdir is fixed at its birth — omit `session` to open one in #{other}",
        refused.content
      opened = call({ "agent" => "plain", "prompt" => "session?", "workdir" => "sub" }, env)
      assert_equal other, JSON.parse(opened.content.lines.first).fetch("cwd")
      missing = call({ "agent" => "plain", "prompt" => "x", "workdir" => "nowhere" }, env)
      assert_predicate missing, :is_error
      assert_equal "Working directory does not exist: #{File.join(root, "nowhere")}", missing.content

      unknown = call({ "agent" => "plain", "prompt" => "x", "session" => "acp-000000000000" }, env)
      assert_predicate unknown, :is_error
      assert_equal "no session acp-000000000000 on this runner; omit `session` to open one", unknown.content
    end
    with_tool_env(conversation: "conv-2") do |env, _root|
      call({ "agent" => "plain", "prompt" => "three" }, env)
      assert_equal 2, sessions.map { |row| row.fetch("pid") }.uniq.length, "another conversation is another child"
    end
  end

  # THE SECRETS never reach the model, the capture or the log: the row's
  # expanded value is erased from the text the child echoes, the prompt
  # line captured, and the child's environment is the scrubbed one plus
  # the row's own.
  def test_the_rows_secret_is_redacted_everywhere_and_the_child_env_is_scrubbed
    Rho::AcpClient.settings_env = { "FX_TOKEN" => RhoAcpClientTest::SECRET }
    load({ "plain" => RhoAcpClientTest.raw_row("plain", "env" => { "FX_TOKEN" => "${FX_TOKEN}" }) })
    row = Rho::AcpClient.rows.fetch(0)
    assert_equal [RhoAcpClientTest::SECRET], row.secrets
    child_env = Rho::AcpClient.child_env(row, ENV.to_h.merge("OPENAI_API_KEY" => "sk-parent-secret", "RHO_HOME" => "/x"))
    assert_equal RhoAcpClientTest::SECRET, child_env.fetch("FX_TOKEN")
    refute child_env.key?("OPENAI_API_KEY"), "the parent's credentials never ride"
    refute child_env.key?("RHO_HOME"), "rho's own never ride"
    refute child_env.keys.any? { |name| name.start_with?("BUNDLE_") }, "Bundler's trail never rides"

    with_tool_env do |env, _root|
      result = call({ "agent" => "plain", "prompt" => "the key is #{RhoAcpClientTest::SECRET}" }, env)
      assert_equal "echo: the key is •••", result.content.lines.first.strip
      refute_includes File.read(result.files.fetch(0), encoding: Encoding::UTF_8), RhoAcpClientTest::SECRET
      refute_includes log_text, RhoAcpClientTest::SECRET
    end
  end

  # ---- the call_tool: the floor, the policy, the id-only request, the progress ----

  def test_the_floor_and_the_policy_answer_the_childs_permission_requests
    load({ "permission" => RhoAcpClientTest.raw_row("permission"),
      "reject" => RhoAcpClientTest.raw_row("permission", "permissions" => "reject"),
      "id-only" => RhoAcpClientTest.raw_row("id_only") })
    protected_path = host.home.settings_path
    tails = []
    with_tool_env do |env, _root, context|
      recorder = Recorder.new(tails)
      context.instance_variable_set(:@progress, recorder)
      result = call({ "agent" => "permission", "prompt" => "run npm test\nrun rm -rf /\nedit #{protected_path}" }, env)
      refute_predicate result, :is_error, result.content
      assert_equal "allowed:allow\nrejected:reject\nrejected:reject", result.content.lines.first(3).join.strip
      assert_match(/· calls: 3 \(2 refused by the floor\) ·/, trailer(result))
      assert_equal({ "calls" => 3, "refused" => 2 }, result.structured_content.slice("calls", "refused"))
      assert_match(/event=acp\.permission agent=permission kind=execute decision=allow by=policy/, log_text)
      assert_match(/event=acp\.permission agent=permission kind=execute decision=reject by=floor reason="recursive delete/, log_text)
      assert_match(/event=acp\.permission agent=permission kind=edit decision=reject by=floor/, log_text)
      lines = capture_lines(result.files.fetch(0))
      decisions = lines.select { |line| line.fetch("dir") == "note" && line["event"] == "permission" }
      assert_equal %w[allow reject reject], decisions.map { |line| line.fetch("decision") }
      assert_equal %w[policy floor floor], decisions.map { |line| line.fetch("by") }

      # The progress tail: one line per tool_call and update, the newest
      # tail handed whole.
      refute_empty tails, "no progress reached the context"
      assert_match(/\[permission\] execute run npm test … pending/, tails.first)
      assert_match(/\[permission\] execute run npm test … completed\n/, tails.last)
      assert_match(/\[permission\] execute run rm -rf \/ … failed/, tails.last)

      rejected = call({ "agent" => "reject", "prompt" => "run npm test" }, env)
      assert_equal "rejected:reject", rejected.content.lines.first.strip
      assert_match(/· calls: 1 \(0 refused by the floor\) ·/, trailer(rejected))
      assert_match(/event=acp\.permission agent=reject kind=execute decision=reject by=policy/, log_text)

      # An id-only request is judged by the tracked tool_call.
      tracked = call({ "agent" => "id-only", "prompt" => "run rm -rf /\nrun npm test" }, env)
      assert_equal "rejected:reject\nallowed:allow", tracked.content.lines.first(2).join.strip
      assert_match(/event=acp\.permission agent=id-only kind=execute decision=reject by=floor/, log_text)
    end
  end

  # ---- cancel and the wall ----

  # `rho stop`: the context's cancel fires the callback, the worker sends
  # `session/cancel` within the grace and raises the runner's own
  # `Cancelled`; the child lives on and its row stands.
  def test_cancel_sends_session_cancel_inside_the_grace_and_the_child_survives
    load({ "sleepy" => RhoAcpClientTest.raw_row("sleep") })
    with_tool_env do |env, _root, context|
      canceller = Thread.new do
        sleep 0.05 until sessions.any? && File.file?(sessions.fetch(0).fetch("capture")) &&
          File.read(sessions.fetch(0).fetch("capture"), encoding: Encoding::UTF_8).include?("agent_message_chunk")
        context.cancel(:canceled)
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(Rho::Runner::ExecutionContext::Cancelled) do
        call({ "agent" => "sleepy", "prompt" => "sleep 10" }, env)
      end
      canceller.join
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 4, "the worker returned inside the grace, not at the child's leisure"
      assert_equal :canceled, error.reason
      row = sessions.fetch(0)
      assert process_group_alive?(row.fetch("pgid")), "a cancelled call keeps the child"
      lines = capture_lines(row.fetch("capture"))
      cancel = lines.find { |line| line.fetch("dir") == "out" && line.dig("message", "method") == "session/cancel" }
      refute_nil cancel, "no session/cancel reached the child"
      assert_match(/event=acp\.cancel_sent agent=sleepy session=#{row.fetch("session")}/, log_text)
      # The child's `cancelled` answer lands after the worker returned; the
      # table's thread logs it.
      answered = await(seconds: 6) do
        capture_lines(row.fetch("capture")).find { |line| line.fetch("dir") == "in" && line.dig("message", "result", "stopReason") == "cancelled" }
      end
      refute_nil answered, "the child's cancelled response was never captured"
    end
  end

  # THE WALL (`timeout_ms`): the same cancel line, then the group killed
  # and reaped; the answer is data, the row gone.
  def test_the_rows_clock_kills_the_group_and_answers_the_timeout_as_data
    load({ "wall" => RhoAcpClientTest.raw_row("sleep", "timeout_ms" => 1500) })
    with_tool_env do |env, _root|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = call({ "agent" => "wall", "prompt" => "sleep 10" }, env)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 5, "the wall is the row's clock"
      assert_predicate result, :is_error
      assert_match(/\Atick( tick)*\n\ndelegate_agent timed out after 1\.5 seconds: acp agent "wall"'s process group was killed; its sessions are gone\n/, result.content)
      assert_match(/· stop: timed_out · calls: 0 \(0 refused by the floor\) ·/, trailer(result))
      assert_empty sessions, "the row is gone"
      pgid = log_text[/event=acp\.child_killed agent=wall .*pgid=(\d+)/, 1]
      refute_nil pgid, "the kill was never logged:\n#{log_text}"
      refute process_group_alive?(Integer(pgid)), "the group #{pgid} survived the wall"
      lines = capture_lines(result.files.fetch(0))
      assert(lines.any? { |line| line.dig("message", "method") == "session/cancel" }, "the cancel line precedes the kill")
    end
  end

  # THE POOL'S CLAMP (the announced park's deadline, `:deadline`) is the
  # same wall: the group killed, the runner's `Cancelled` raised so the
  # run answers `timed_out`.
  def test_the_contexts_deadline_kills_the_group_and_raises_the_deadline
    load({ "sleepy" => RhoAcpClientTest.raw_row("sleep") })
    with_tool_env do |env, _root, context|
      Thread.new do
        sleep 0.05 until sessions.any?
        sleep 0.3
        context.cancel(:deadline)
      end
      error = assert_raises(Rho::Runner::ExecutionContext::Cancelled) { call({ "agent" => "sleepy", "prompt" => "sleep 10" }, env) }
      assert_equal :deadline, error.reason
      assert_empty sessions
      pgid = log_text[/event=acp\.child_killed agent=sleepy .*pgid=(\d+)/, 1]
      refute_nil pgid, log_text
      refute process_group_alive?(Integer(pgid))
    end
  end

  # ---- a death, the auth doors, the version, the elicitation, the model ----

  def test_a_child_that_dies_mid_turn_is_answered_by_name_and_never_revived
    load({ "die" => RhoAcpClientTest.raw_row("die") })
    with_tool_env do |env, _root|
      result = call({ "agent" => "die", "prompt" => "go" }, env)
      assert_predicate result, :is_error
      session = result.structured_content.fetch("session")
      assert_match(/\Aabout to go\n\nacp agent "die" exited \(status 3\) during the delegation; its stderr ended: fixture agent: dying with status 3\n/,
        result.content)
      assert_match(/· stop: exited · /, trailer(result))
      assert_empty sessions, "the dead child's rows are gone"
      assert_match(/event=acp\.child_exited agent=die .*exit="status 3"/, log_text)

      again = call({ "agent" => "die", "prompt" => "go", "session" => session }, env)
      assert_predicate again, :is_error
      assert_equal "session #{session}'s agent \"die\" exited (status 3); the session is gone — omit `session` to open one", again.content
      fresh = call({ "agent" => "die", "prompt" => "go" }, env)
      refute_equal session, fresh.structured_content.fetch("session"), "a new child, a new session"
    end
  end

  def test_the_auth_doors
    load({ "auth" => RhoAcpClientTest.raw_row("auth_required", "auth_method" => "fixture-login"),
      "sole" => RhoAcpClientTest.raw_row("auth_required"),
      "terminal" => RhoAcpClientTest.raw_row("terminal_auth_only") })
    with_tool_env do |env, _root|
      result = call({ "agent" => "auth", "prompt" => "hi" }, env)
      refute_predicate result, :is_error, result.content
      lines = capture_lines(result.files.fetch(0))
      authenticate = lines.find { |line| line.dig("message", "method") == "authenticate" }
      assert_equal "fixture-login", authenticate.dig("message", "params", "methodId")
      assert_equal 2, lines.count { |line| line.dig("message", "method") == "session/new" }, "session/new, -32000, authenticate, session/new"

      sole = call({ "agent" => "sole", "prompt" => "hi" }, env)
      refute_predicate sole, :is_error, "the sole agent-type method is taken without a row's word: #{sole.content}"

      refused = call({ "agent" => "terminal", "prompt" => "hi" }, env)
      assert_predicate refused, :is_error
      assert_equal 'acp_auth_required: acp agent "terminal" needs a login this runner cannot perform (its methods: login (terminal)); ' \
                   "run its own program's login by hand, then `rho acp-agents probe terminal`", refused.content
      assert_empty sessions.select { |row| row.fetch("agent") == "terminal" }, "a child that refused a session is closed"
    end
  end

  def test_a_protocol_version_other_than_one_is_refused_and_the_child_closed
    load({ "v2" => RhoAcpClientTest.raw_row("plain", "args" => [RhoAcpClientTest::AGENT, "--mode", "plain", "--protocol-version", "2"]) })
    with_tool_env do |env, _root|
      result = call({ "agent" => "v2", "prompt" => "hi" }, env)
      assert_predicate result, :is_error
      assert_equal 'acp_version: acp agent "v2" speaks protocol version 2; this client speaks 1', result.content
      assert_empty sessions
    end
  end

  def test_an_elicitation_is_declined_and_quoted
    load({ "elicit" => RhoAcpClientTest.raw_row("elicit") })
    with_tool_env do |env, _root|
      result = call({ "agent" => "elicit", "prompt" => "hi" }, env)
      refute_predicate result, :is_error, result.content
      assert_equal "elicitation:decline", result.content.lines.first.strip
      assert_includes result.content, "\nthe agent asked: Which colour? — declined; prompt the session again with an answer\n"
    end
  end

  def test_the_rows_model_is_set_when_the_child_lists_the_option
    load({ "model" => RhoAcpClientTest.raw_row("model_option", "model" => "fx-large"),
      "default" => RhoAcpClientTest.raw_row("model_option"),
      "deaf" => RhoAcpClientTest.raw_row("plain", "model" => "fx-large") })
    with_tool_env do |env, _root|
      assert_equal "model:fx-large", call({ "agent" => "model", "prompt" => "hi" }, env).content.lines.first.strip
      assert_equal "model:fx-small", call({ "agent" => "default", "prompt" => "hi" }, env).content.lines.first.strip
      deaf = call({ "agent" => "deaf", "prompt" => "hi" }, env)
      refute_predicate deaf, :is_error, "a child listing no model option is prompted without one"
      refute(capture_lines(deaf.files.fetch(0)).any? { |line| line.dig("message", "method") == "session/set_config_option" })
    end
  end

  # ---- release, the sweep, the kill ----

  def test_release_closes_the_conversations_sessions_and_ends_its_child
    load({ "plain" => RhoAcpClientTest.raw_row("plain") })
    # The captures live under each root's artifacts, so both roots stand
    # while the release is read.
    with_tool_env(conversation: "conv-x") do |env, _root|
      call({ "agent" => "plain", "prompt" => "one" }, env)
      with_tool_env(conversation: "conv-y") { |other, _r| call({ "agent" => "plain", "prompt" => "two" }, other) }
      rows = sessions
      assert_equal 2, rows.length
      ended = rows.find { |row| row.fetch("conversation") == "conv-x" }
      Rho::AcpClient.release("conv-x")
      assert await { sessions.none? { |row| row.fetch("conversation") == "conv-x" } ? true : nil }, "conv-x's rows stayed"
      assert await { process_group_alive?(ended.fetch("pgid")) ? nil : true }, "conv-x's child survived"
      assert_equal 1, sessions.length, "conv-y's child stands"
      assert_match(/event=acp\.host_ended conversation=conv-x children=1/, log_text)
      closed = await { capture_lines(ended.fetch("capture")).find { |line| line.dig("message", "method") == "session/close" } }
      refute_nil closed, "the session was closed before the child was stopped"
    end
  end

  def test_the_sweep_retires_a_child_that_died_between_calls_and_kill_ends_one_by_session
    load({ "plain" => RhoAcpClientTest.raw_row("plain") })
    with_tool_env do |env, _root|
      first = call({ "agent" => "plain", "prompt" => "one" }, env).structured_content.fetch("session")
      row = sessions.fetch(0)
      Process.kill("KILL", row.fetch("pid"))
      assert await { Rho::AcpClient.sweep!.positive? ? true : nil }, "the sweep never retired the dead child"
      assert_empty sessions
      assert_match(/event=acp\.child_exited agent=plain .*exit="signal 9"/, log_text)
      again = call({ "agent" => "plain", "prompt" => "x", "session" => first }, env)
      assert_equal "session #{first}'s agent \"plain\" exited (signal 9); the session is gone — omit `session` to open one", again.content

      second = call({ "agent" => "plain", "prompt" => "two" }, env).structured_content.fetch("session")
      pgid = sessions.fetch(0).fetch("pgid")
      assert_equal true, Rho::AcpClient.kill(second)
      assert_empty sessions
      refute process_group_alive?(pgid)
      assert_equal false, Rho::AcpClient.kill(second), "a second kill has nothing to end"
    end
  end
end
