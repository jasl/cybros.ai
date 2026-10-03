require "test_helper"
require "tmpdir"

# The four tools and the three hooks, against a real table of real
# processes — the answers a model reads are the product, so they are
# asserted by their text.
class ProcessesExtensionTest < Minitest::Test
  # The kernel's word on each loop's inbox row, as the execution context
  # carries it: loop-a and loop-b belong to one conversation, loop-c to
  # another; a loop named no conversation is a standalone loop.
  CONVERSATIONS = { "loop-a" => "conv-1", "loop-b" => "conv-1", "loop-c" => "conv-2" }.freeze

  def setup
    @dir = Dir.mktmpdir("rho-procs-ext")
    @registry = Rho::Processes::Registry.new(
      log_dir: File.join(@dir, "log"),
      state_file: Rho::StateFile.new(File.join(@dir, "processes.json"))
    )
    @env = Rho::Runner::ToolEnv.new(root: @dir, artifacts_dir: File.join(@dir, "artifacts"), processes: @registry)
  end

  def teardown
    @registry.close
    FileUtils.rm_rf(@dir)
  end

  # The handle a daemon hands out, carrying this test's table as its host's.
  def daemon_api
    host = RhoTest.host.with(processes: @registry)
    Rho::Extensions::Api.new(extension_name: "rho.processes", source: "<test>", host: host)
  end

  def tool(klass) = klass.new(env: @env)
  def start(args) = tool(Rho::Extensions::Processes::Tools::StartProcess).call(args)

  def as_loop(public_id, &)
    context = Rho::Runner::ExecutionContext.new(agent_loop_public_id: public_id, task_key: "t1",
      conversation_public_id: CONVERSATIONS[public_id])
    Rho::Runner::ExecutionContext.with(context, &)
  end

  # ---- the leader-exit / pipe-EOF beat, staged without a race ----

  # An output whose writers are gone `eof_after` seconds after it was
  # made — the pump's `eof!` a beat behind the reaper's poll, on a clock
  # rather than a thread, so the beat is exactly as long as the test says.
  class LaggingOutput < Rho::Processes::Output
    def initialize(path:, eof_after:)
      super(path: path)
      @eof_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + eof_after
    end

    def eof? = super || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @eof_at
  end

  # A leader that has already exited 0, as the registry's guard reports one.
  ExitedProcess = Data.define(:pid, :group_pid) do
    def poll = Data.define(:exitstatus, :termsig).new(exitstatus: 0, termsig: nil)
  end

  # The registry's own row over that process and that output.
  def exited_row(eof_after:)
    FileUtils.mkdir_p(File.join(@dir, "log"))
    output = LaggingOutput.new(path: File.join(@dir, "log", "p1.log"), eof_after: eof_after)
    output.append("forked\n")
    Rho::Processes::Row.new(
      id: "p1", name: nil, command: "echo forked; exit 0", workdir: @dir, owner: nil, loop: nil,
      process: ExitedProcess.new(pid: 4242, group_pid: 4242), started_at: Time.now, output: output, stdin: StringIO.new
    )
  end

  # `start_process` over a table that answers that one row.
  def start_over(row, args)
    table = Object.new
    table.define_singleton_method(:start) { |**| row }
    env = Rho::Runner::ToolEnv.new(root: @dir, artifacts_dir: File.join(@dir, "artifacts"), processes: table)
    Rho::Extensions::Processes::Tools::StartProcess.new(env: env).call({ "command" => row.command }.merge(args))
  end

  def test_registers_the_models_four_tools_the_persons_read_and_the_three_hooks
    api = daemon_api
    Rho::Extensions::Processes.register(api)

    assert_equal %w[start_process list_processes read_process stop_process process_log],
      api.tools.map { |registration| registration.klass::NAME }
    assert_equal %i[tool_result], api.hooks.map(&:event)
    assert_equal %i[startup shutdown], api.lifecycle.map(&:event)
    assert_equal 1, api.environment_descriptions.size
    assert_equal 3, api.routes.size
    assert_equal %w[processes kill logs], api.commands.map(&:name)
    assert_equal %w[rho.processes.sweep rho.processes.progress], api.background_tasks.map(&:name),
      "the validity sweep and the watcher's pump ride the daemon"
  end

  # A standalone runner loads the same extension: no host, so no table,
  # and the routes and verbs it registers are logged away, never raised.
  def test_loads_under_the_base_handle_with_no_host_and_no_table
    log = RecordingLog.new
    api = Rho::Runner::Extensions::Api.new(extension_name: "rho.processes", source: "<test>", log: log)
    Rho::Extensions::Processes.register(api)

    assert_nil api.host
    assert_equal 5, api.tools.size
    assert_equal %i[startup shutdown], api.lifecycle.map(&:event)
    assert_nil api.environment_descriptions.first.handler.call(nil)
    assert_nil api.hooks.first.handler.call("ls", Rho::Runner::Result.ok("x"))
    api.lifecycle.each { |registration| assert_nil registration.handler.call }
    unavailable = log.lines.select { |event, _| event == "extension_verb_unavailable" }.map { |_, fields| fields[:detail] }
    assert_equal 8, unavailable.size, unavailable.inspect
    assert unavailable.all? { |detail| detail.match?(/\A(route|command|background task) .* is not surfaced by a standalone runner\z/) }
  end

  def test_the_answer_has_the_header_a_model_reads_by_eye
    result = start("command" => "echo Listening on http://localhost:4567; sleep 30",
      "name" => "web", "wait_for" => "listening on", "wait_seconds" => 5)

    refute result.is_error, result.content
    lines = result.content.lines.map(&:chomp)
    assert_match(/\Ap1 \(pid \d+\) running — web\z/, lines[0])
    assert_equal "ready: Listening on http://localhost:4567", lines[1]
    assert_equal "log: #{File.join(@dir, "log", "p1.log")}", lines[2]
    assert_equal "workdir: #{@dir}", lines[3]
    assert_includes result.content, "\n\nListening on http://localhost:4567"
    assert_equal "p1", result.structured_content["id"]
    assert_equal "running", result.structured_content["status"]
  end

  def test_a_command_that_exits_nonzero_is_an_error_the_model_reads
    result = start("command" => "echo nope >&2; exit 2", "wait_seconds" => 5)

    assert result.is_error
    assert_match(/\Ap1 \(pid \d+\) exited\n/, result.content)
    assert_includes result.content, "exited with status 2 after"
    assert_includes result.content, "nope"
  end

  def test_a_daemonizing_launcher_is_told_what_it_lost
    result = start("command" => "echo forked; exit 0", "wait_seconds" => 5)

    refute result.is_error
    assert_includes result.content, "run servers in the foreground (no -d, --daemon, nohup or &)"
  end

  # THE LEADER EXITS A BEAT BEFORE ITS PIPE (the 1-in-15 shape of the test
  # above): the reaper's poll answers the exit while the pump has not yet
  # closed the output. `wait` grants that one beat, so a plain exit is
  # `exited` with the foreground sentence — never "something it started
  # still holds its output". The row is the registry's own, over an
  # output whose EOF lands 20 ms after the leader's exit.
  def test_a_leader_that_exits_a_beat_before_its_pipe_eof_is_exited
    result = start_over(exited_row(eof_after: 0.02), "wait_seconds" => 5)

    refute result.is_error, result.content
    assert_equal "exited", result.structured_content["status"]
    assert_includes result.content, "exited with status 0 after"
    assert_includes result.content, "run servers in the foreground (no -d, --daemon, nohup or &)"
  end

  # The beat is bounded by the caller's budget: a zero wait answers what
  # the table says at once, and an EOF a full second away is not waited for.
  def test_the_eof_grace_never_passes_the_callers_deadline
    result = start_over(exited_row(eof_after: 1), "wait_seconds" => 0)

    assert_equal "running", result.structured_content["status"]
    assert_includes result.content, "something it started still holds its output"
  end

  def test_still_starting_says_what_it_waited_for
    result = start("command" => "sleep 30", "wait_for" => "ready in", "wait_seconds" => 0.3)

    refute result.is_error
    assert_includes result.content, 'still starting after 0.3s (no line contained "ready in" yet'
    assert_includes result.content, "no output yet"
  end

  # AN AGENT-MODE DAEMON SERVES NO RUNNER TOOL AND KEEPS THE VERBS: the extension loads there for `rho ps`/`rho logs`, which read a
  # bound runner's table through the relay, and registers nothing the mode
  # would refuse.
  def test_under_an_agent_mode_daemon_the_verbs_register_and_the_tools_do_not
    host = RhoTest.host.with(processes: @registry, config: Rho::Config.from_hash("mode" => "agent"))
    api = Rho::Extensions::Api.new(extension_name: "rho.processes", source: "<test>", host: host)
    Rho::Extensions::Processes.register(api)

    assert_empty api.tools
    assert_equal %w[processes kill logs], api.commands.map(&:name)
    assert_equal 3, api.routes.size
  end

  # THE PERSON'S READ OF ANY ROW: `process_log` shares
  # the daemon's log door body and carries no owner gate — a relay loop is
  # a standalone caller whose `read_process` the registry refuses on a
  # conversation-owned row; the recorded semantic difference between the
  # two tools is exactly that read. Live rows, the remembered exit of a
  # dead one, and an id nobody knows.
  def test_process_log_reads_a_conversation_owned_row_the_models_read_process_refuses
    as_loop("loop-a") { start("command" => "echo up; sleep 30", "wait_for" => "up", "wait_seconds" => 5) }

    refused = as_loop("relay-loop") { tool(Rho::Extensions::Processes::Tools::ReadProcess).call("id" => "p1") }
    assert refused.is_error
    assert_match(/belongs to conversation conv-1/, refused.content)

    read = as_loop("relay-loop") { tool(Rho::Extensions::Processes::Tools::ProcessLog).call("id" => "p1", "lines" => 5) }
    refute read.is_error, read.content
    assert_match(/\Ap1  running  pid \d+  owner conv-1  loop loop-a  echo up; sleep 30/, read.content)
    assert_match(/\n\nup\z/, read.content)
    assert_equal ["up"], read.structured_content.fetch(:lines)
    assert_equal "p1", read.structured_content.dig(:process, "id")
    assert_equal @registry.row("p1").output.path, read.structured_content.fetch(:path)

    @registry.stop("p1", by: "user")
    dead = tool(Rho::Extensions::Processes::Tools::ProcessLog).call("id" => "p1")
    refute dead.is_error, dead.content
    assert_equal "exited", dead.structured_content.dig(:process, "status")
    assert_match(/\Ap1  exited \(signal TERM/, dead.content)

    unknown = tool(Rho::Extensions::Processes::Tools::ProcessLog).call("id" => "p9")
    assert unknown.is_error
    assert_equal "no process p9", unknown.content
    assert_nil Rho::Extensions::Processes::Tools::ProcessLog::DESCRIPTION, "described to nobody"
  end

  # THE OWNER IS THE CONVERSATION, the loop kept for display: a sibling loop of the
  # conversation reads and stops it; a loop of another conversation is refused by name, on
  # the read and on the stop.
  def test_the_owner_is_the_conversation_of_the_loop_that_called
    as_loop("loop-a") { start("command" => "echo up; sleep 30", "wait_for" => "up", "wait_seconds" => 5) }

    snapshot = @registry.snapshots.first
    assert_equal "conv-1", snapshot.owner
    assert_equal "loop-a", snapshot.loop
    listing = as_loop("loop-c") { tool(Rho::Extensions::Processes::Tools::ListProcesses).call({}) }
    assert_match(/\Ap1  running  pid \d+  owner conv-1  loop loop-a  echo up; sleep 30/, listing.content)
    denied = as_loop("loop-c") { tool(Rho::Extensions::Processes::Tools::ReadProcess).call("id" => "p1") }
    assert denied.is_error
    assert_equal "p1 belongs to conversation conv-1; only its loops, or the person (rho kill p1), may read it", denied.content
    denied = as_loop("loop-c") { tool(Rho::Extensions::Processes::Tools::StopProcess).call("id" => "p1") }
    assert denied.is_error
    assert_equal "p1 belongs to conversation conv-1; only its loops, or the person (rho kill p1), may stop it", denied.content
    read = as_loop("loop-b") { tool(Rho::Extensions::Processes::Tools::ReadProcess).call("id" => "p1") }
    refute read.is_error, read.content
    assert_match(/\n\nup\z/, read.content)
    allowed = as_loop("loop-b") { tool(Rho::Extensions::Processes::Tools::StopProcess).call("id" => "p1") }
    refute allowed.is_error
    assert_match(/p1 stopped: exited with signal TERM/, allowed.content)
  end

  # THE DEAD CALL: the one new model-facing sentence — the exit, the entry is gone, a
  # restart is a new id — with the log's tail under it; the next start_process answers p2.
  def test_a_call_against_a_dead_process_names_the_exit_and_says_the_entry_is_gone
    died = as_loop("loop-a") { start("command" => "echo bye; exit 2", "wait_seconds" => 5) }
    assert died.is_error
    wait_for { @registry.row("p1").nil? }

    read = as_loop("loop-a") { tool(Rho::Extensions::Processes::Tools::ReadProcess).call("id" => "p1") }
    assert read.is_error
    sentence = "p1 exited with status 2, on its own; the entry is gone — start_process again gives a new id. " \
               "Its log: #{File.join(@dir, "log", "p1.log")}"
    assert_equal "#{sentence}\n\nbye\n[rho] p1: leader exited with status 2, on its own; the group ended at " \
                 "#{read.content[/the group ended at (\S+)\z/, 1]}", read.content
    assert_equal "p1", read.structured_content["id"]
    assert_equal "exited", read.structured_content["status"]
    stopped = as_loop("loop-c") { tool(Rho::Extensions::Processes::Tools::StopProcess).call("id" => "p1") }
    assert stopped.is_error
    assert_equal sentence, stopped.content
    again = as_loop("loop-a") { start("command" => "sleep 30", "wait_seconds" => 0) }
    refute again.is_error
    assert_match(/\Ap2 \(pid \d+\) running/, again.content)
  end

  def test_list_and_read
    start("command" => "echo one; echo two; sleep 30", "name" => "svc", "wait_for" => "two", "wait_seconds" => 5)

    listing = tool(Rho::Extensions::Processes::Tools::ListProcesses).call({})
    # The ready line is the one that matched wait_for, not the first line.
    assert_match(/\Ap1  running  pid \d+  owner -  svc  \(#{Regexp.escape(@dir)}\)\n    two/, listing.content)
    assert_equal 1, listing.structured_content["processes"].size

    read = tool(Rho::Extensions::Processes::Tools::ReadProcess).call("id" => "p1", "tail_lines" => 1)
    assert_match(/\n\ntwo\z/, read.content)

    unknown = tool(Rho::Extensions::Processes::Tools::ReadProcess).call("id" => "p7")
    assert unknown.is_error
    assert_includes unknown.content, "known: p1"
  end

  def test_a_missing_workdir_and_a_missing_command_are_refused
    assert start("command" => "   ").is_error
    result = start("command" => "sleep 1", "workdir" => "nowhere")
    assert result.is_error
    assert_includes result.content, "Working directory does not exist"
  end

  def test_the_environment_sentence_appears_only_while_something_runs
    api = daemon_api
    Rho::Extensions::Processes.register(api)
    describe = api.environment_descriptions.first.handler

    assert_nil describe.call(nil)
    start("command" => "sleep 30", "wait_seconds" => 0)
    assert_equal Rho::Extensions::Processes::ENVIRONMENT_SENTENCE, describe.call(nil)
  end

  def test_the_owning_loop_hears_once_on_its_next_tool_result
    api = daemon_api
    Rho::Extensions::Processes.register(api)
    hook = api.hooks.first.handler
    row = as_loop("loop-a") { start("command" => "sleep 30", "name" => "web", "wait_seconds" => 0) }
    @registry.stop("p1", by: "user")
    # EOF can arrive before the leader's status is available to settle.
    # Drive the daemon's ordinary fallback sweep, then wait for retirement
    # and the owner's notice, which are recorded under the same mutex.
    wait_for do
      @registry.sweep_dead!
      @registry.row("p1").nil?
    end

    result = Rho::Runner::Result.ok("ls output")
    told = as_loop("loop-b") { hook.call("ls", result) }
    assert_match(/\Als output\n\nNOTE: process p1 \(web\) \(pid \d+\) exited with signal TERM, stopped by the person/, told.content)
    assert_nil as_loop("loop-a") { hook.call("ls", result) }, "once, to the conversation"
    assert_nil as_loop("loop-c") { hook.call("ls", result) }, "not somebody else's"
    assert_equal "p1", row.structured_content["id"]
  end

  def test_without_a_table_the_tools_say_so
    @env = Rho::Runner::ToolEnv.new(root: @dir, artifacts_dir: File.join(@dir, "artifacts"), processes: nil)

    result = start("command" => "sleep 1")
    assert result.is_error
    assert_includes result.content, "no daemon"
    assert tool(Rho::Extensions::Processes::Tools::ListProcesses).call({}).is_error
  end

  class RecordingLog
    attr_reader :lines

    def initialize = @lines = []
    def info(event, **fields) = @lines << [event, fields]
    def warn(event, **fields) = @lines << [event, fields]
  end

  private

    def wait_for(seconds = 3)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      until yield
        flunk "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.02
      end
    end
end
