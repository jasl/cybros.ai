require "test_helper"

# THE PROCESSES A LOOP STARTED, AS THE PERSON SEES THEM, with the extension
# loaded alone: listed, read and killed
# over the control surface, and ended by the extension's own shutdown
# hook when the daemon stops. The tools are in test/rho/processes.
class ProcessesRoutesTest < Minitest::Test
  include RhoTest::DaemonHarness

  def boot(extensions: [Rho::Extensions::Processes], **options) = super(extensions: extensions, **options)

  def test_processes_are_listed_logged_and_killed_through_the_control_surface
    daemon = boot
    token = bearer(daemon)
    empty = JSON.parse(request(daemon, :get, "/processes", token: token).body)
    assert_equal [], empty.fetch("processes")

    row = daemon.host.processes.start(command: "echo up; sleep 30", workdir: @root, env: Rho::Runner::ChildEnv.call,
      name: "web", loop: "loop-a", wait_for: "up")
    wait_for { row.output.matched? }

    listing = JSON.parse(request(daemon, :get, "/processes", token: token).body).fetch("processes")
    assert_equal ["p1"], listing.map { |r| r["id"] }
    # A loop this daemon does not follow owns by its own id.
    assert_equal "loop-a", listing.first["owner"]
    assert_equal "loop-a", listing.first["loop"]
    assert_equal "up", listing.first["ready_line"]

    log = JSON.parse(request(daemon, :get, "/processes/log?id=p1&lines=5", token: token).body)
    assert_equal ["up"], log.fetch("lines")
    assert_equal row.output.path, log.fetch("path")

    response = request(daemon, :post, "/processes/stop", token: token, body: { id: "p1" })
    assert_equal "202", response.code, "signal now, answer now; the grace is the registry's own thread"
    assert_equal "stopping", JSON.parse(response.body).dig("process", "status")
    wait_for { daemon.host.processes.row("p1").nil? }
    refute row.live?
    assert_equal "user", row.snapshot.stopped_by

    # THE ENTRY IS GONE, THE EXIT IS KEPT: the listing is empty, the log door answers the
    # remembered exit with the file's tail, and a second stop is 404 with the dead-call
    # sentence.
    assert_equal [], JSON.parse(request(daemon, :get, "/processes", token: token).body).fetch("processes")
    after = JSON.parse(request(daemon, :get, "/processes/log?id=p1&lines=5", token: token).body)
    assert_equal "exited", after.dig("process", "status")
    assert_equal "TERM", after.dig("process", "signal")
    assert_equal "up", after.fetch("lines").first
    assert_match(/\A\[rho\] p1 \(web\): leader exited with signal TERM, stopped by the person; the group ended at/,
      after.fetch("lines").last)
    refused = request(daemon, :post, "/processes/stop", token: token, body: { id: "p1" })
    assert_equal "404", refused.code
    assert_match(/p1 \(web\) exited with signal TERM, stopped by the person; the entry is gone/,
      JSON.parse(refused.body).dig("error", "message"))

    assert_equal "404", request(daemon, :get, "/processes/log?id=p9", token: token).code
    assert_equal "404", request(daemon, :post, "/processes/stop", token: token, body: { id: "p9" }).code
    assert_equal "400", request(daemon, :post, "/processes/stop", token: token, body: {}).code
  end

  # THE CONVERSATION ENDED HERE: the daemon's Loops forgetting a host — the loop terminal
  # of a standalone loop, a conversation the kernel answered 404 for — kills the groups
  # that host's loop started and removes their entries; a group of another host stands.
  def test_forgetting_a_host_ends_the_processes_its_loop_started
    daemon = boot
    ours = daemon.host.processes.start(command: "sleep 30", workdir: @root, env: Rho::Runner::ChildEnv.call,
      loop: "loop-a")
    theirs = daemon.host.processes.start(command: "sleep 30", workdir: @root, env: Rho::Runner::ChildEnv.call,
      loop: "loop-b")

    daemon.loops.forget(Rho::Host::AgentLoop.new(public_id: "loop-a"))

    wait_for { daemon.host.processes.row("p1").nil? }
    refute ours.live?
    assert_equal "conversation_ended", ours.snapshot.stopped_by
    # The ladder reaps on its own thread a beat after the pipe closed; on
    # macOS a group of nothing but zombies answers EPERM until then.
    wait_for { group_gone?(ours.pgid) }
    assert_equal "running", theirs.snapshot.status
    assert_same theirs, daemon.host.processes.row("p2")
  end

  def test_stopping_the_daemon_ends_the_processes_it_owns
    daemon = boot
    row = daemon.host.processes.start(command: "sleep 30", workdir: @root, env: Rho::Runner::ChildEnv.call)

    daemon.stop

    assert_equal "exited", row.snapshot.status
    assert_equal "shutdown", row.snapshot.stopped_by
    assert_raises(Errno::ESRCH) { Process.kill(0, -row.pgid) }
  end

# THE REASON THE TABLE IS BOUND AT REGISTRATION:
# two daemons in one process hold two tables, and stopping one ends
# only the processes it owns. A hook that looked a table up at call
# time, or a process-global, would close the other daemon's here.
def test_two_daemons_in_one_process_keep_separate_tables
  other = Dir.mktmpdir("rho-processes-other")
  first = boot
  second = boot(base_url: "https://other.example", root: other)
  refute_same first.host.processes, second.host.processes

  row = second.host.processes.start(command: "sleep 30", workdir: other, env: Rho::Runner::ChildEnv.call)
  first.stop

  assert_equal "running", row.snapshot.status
  assert_equal 1, Process.kill(0, -row.pgid)
  second.stop
  assert_equal "shutdown", row.snapshot.stopped_by
ensure
  FileUtils.remove_entry(other) if other && File.directory?(other)
end

  def test_the_process_table_lives_under_home_not_the_project
    daemon = boot

    assert_equal File.join(daemon.home.log_root, "processes"), daemon.host.processes.log_dir
  end

  def test_the_process_routes_are_authenticated_like_every_other_control_route
    daemon = boot

    assert_equal "401", request(daemon, :get, "/processes").code
    assert_equal "401", request(daemon, :post, "/processes/stop", body: { id: "p1" }).code
  end

  # THE TABLE ELSEWHERE: a followed host bound to a runner that
  # is not this machine's has its rows THERE, and the listing carries them —
  # read through ONE relayed `list_processes` per runner, each row naming
  # the runner it lives on — beside this machine's own. This daemon's own
  # runner and a host with no binding are not remote; the honest line about
  # where the rows are not is gone.
  def test_the_listing_carries_the_rows_of_the_runners_followed_hosts_are_bound_to
    remote_row = { "id" => "p4", "status" => "running", "pid" => 77, "owner" => "c-1", "loop" => "al-9",
                   "command" => "python3 -m http.server", "workdir" => "/srv", "name" => "web" }
    api = NexusDoubles::FakeAgentApi.new(task_detail: {
      "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "list_processes",
      "output" => "p4  running  pid 77", "structured_content" => { "processes" => [remote_row] },
      "on_failure" => "propagate", "visibility" => "visible", "created_at" => "2026-09-13T00:00:00Z",
    })
    daemon = member_ready(boot(extensions: [Rho::Extensions::Processes, Rho::Runner::Extensions::Coding]),
      api, identity: RUNNER_IDENTITY)
    store = host_store(daemon)
    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1", runner: "0199-h")
    store.remember(Rho::Host::Conversation.new(public_id: "c-5"), workspace: "ws-1", runner: "0199-h")
    store.remember(Rho::Host::Conversation.new(public_id: "c-2"), workspace: "ws-1", runner: "0199-runner")
    store.remember(Rho::Host::AgentLoop.new(public_id: "al-3"), workspace: "ws-1")

    document = JSON.parse(request(daemon, :get, "/processes", token: bearer(daemon)).body)

    assert_equal [remote_row.merge("runner" => "0199-h")], document.fetch("processes")
    assert_equal [], document.fetch("unreachable")
    refute document.key?("remote"), "the honest line is gone: the rows themselves are here"
    authored = api.loop_creates.map { |body| body.dig("agent_loop", "steps", 0, "tool") }
    assert_equal [{ "name" => "list_processes", "input" => {}, "key" => "relay",
                    "timeout_ms" => Rho::Extensions::Processes::Remote::TIMEOUT_MS }], authored,
      "ONE relay for the one remote runner two hosts share; this daemon's own runner is read from the table"
    assert_equal "0199-h", api.loop_creates.first.dig("agent_loop", "runner_executor_public_id")
    paths = api.requests.map(&:first)
    assert(paths.any? { |path| path.end_with?("/agent_loops/al-1/start") }, "created AND started")
  end

  # A runner that could not answer — offline, the row swept `timed_out` and
  # the composition's stop behind it — is ONE `unreachable` entry with the
  # error key, never a listing that looks empty or a 500.
  def test_a_runner_that_cannot_answer_is_one_unreachable_entry
    api = NexusDoubles::FakeAgentApi.new(task_detail: {
      "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "timed_out", "tool_name" => "list_processes",
      "error" => { "key" => "tool_timeout", "detail" => "nobody claimed it" },
      "on_failure" => "propagate", "visibility" => "visible", "created_at" => "2026-09-13T00:00:00Z",
    })
    daemon = member_ready(boot(extensions: [Rho::Extensions::Processes, Rho::Runner::Extensions::Coding]),
      api, identity: RUNNER_IDENTITY)
    host_store(daemon)
      .remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1", runner: "0199-h")

    document = JSON.parse(request(daemon, :get, "/processes", token: bearer(daemon)).body)

    assert_equal [], document.fetch("processes")
    assert_equal [{ "runner" => "0199-h", "error" => "tool_timeout" }], document.fetch("unreachable")
    assert(api.requests.map(&:first).any? { |path| path.end_with?("/agent_loops/al-1/stop") }, "stopped behind the failure")
  end

  # ONE ROW'S TAIL from a runner elsewhere: `runner=` names the table and
  # the read is a relayed `process_log` (the person's tool — the model's `read_process` would refuse a relay caller by ownership); without the
  # flag an id this machine does not know is asked of the ONE runner the
  # followed hosts are bound to.
  def test_the_log_door_reads_a_row_elsewhere_through_process_log
    api = NexusDoubles::FakeAgentApi.new(task_detail: {
      "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "process_log",
      "output" => "p4  running  pid 77\n\nGET / 200",
      "structured_content" => { "process" => { "id" => "p4", "status" => "running" }, "path" => "/log/p4.log",
                                "lines" => ["GET / 200"] },
      "on_failure" => "propagate", "visibility" => "visible", "created_at" => "2026-09-13T00:00:00Z",
    })
    daemon = member_ready(boot(extensions: [Rho::Extensions::Processes, Rho::Runner::Extensions::Coding]),
      api, identity: RUNNER_IDENTITY)
    host_store(daemon)
      .remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1", runner: "0199-h")

    named = JSON.parse(request(daemon, :get, "/processes/log?id=p4&lines=3&runner=0199-h", token: bearer(daemon)).body)
    assert_equal({ "process" => { "id" => "p4", "status" => "running", "runner" => "0199-h" },
                   "path" => "/log/p4.log", "lines" => ["GET / 200"] }, named)
    assert_equal({ "name" => "process_log", "input" => { "id" => "p4", "lines" => 3 }, "key" => "relay",
                   "timeout_ms" => Rho::Extensions::Processes::Remote::TIMEOUT_MS },
      api.loop_creates.first.dig("agent_loop", "steps", 0, "tool"))

    unnamed = JSON.parse(request(daemon, :get, "/processes/log?id=p4", token: bearer(daemon)).body)
    assert_equal "0199-h", unnamed.dig("process", "runner"), "the one remote runner is asked when the table has no p4"
    assert_equal 2, api.loop_creates.length
  end

  # THE INFERENCE BEHIND THE BARE `rho logs ID` (routes.rb `log_document` / `not_found`): an id this machine's table does not know is
  # asked of the ONE runner the followed hosts are bound to; with SEVERAL
  # remote runners nothing is inferred — the 404 names the flag that picks
  # a table — and with none the 404 is the plain sentence. The bindings
  # are read from the store on every request, so one daemon walks the
  # three counts: none, one (the relay names it), two (no relay at all).
  def test_the_log_door_infers_the_one_remote_runner_and_names_the_flag_for_several
    api = NexusDoubles::FakeAgentApi.new(task_detail: {
      "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "process_log",
      "output" => "p9  running  pid 91\n\nready",
      "structured_content" => { "process" => { "id" => "p9", "status" => "running" }, "path" => "/log/p9.log",
                                "lines" => ["ready"] },
      "on_failure" => "propagate", "visibility" => "visible", "created_at" => "2026-09-13T00:00:00Z",
    })
    daemon = member_ready(boot(extensions: [Rho::Extensions::Processes, Rho::Runner::Extensions::Coding]),
      api, identity: RUNNER_IDENTITY)
    store = host_store(daemon)
    token = bearer(daemon)

    none = request(daemon, :get, "/processes/log?id=p9&lines=2", token: token)
    assert_equal "404", none.code
    assert_equal({ "code" => "process_not_found", "message" => "no process p9" }, JSON.parse(none.body).fetch("error"),
      "no remote runner: nothing to ask, the plain sentence")
    assert_empty api.loop_creates

    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1", runner: "0199-h")
    one = JSON.parse(request(daemon, :get, "/processes/log?id=p9&lines=2", token: token).body)
    assert_equal "0199-h", one.dig("process", "runner"), "one remote runner: inferred, its answer is the document"
    assert_equal 1, api.loop_creates.length
    assert_equal "0199-h", api.loop_creates.first.dig("agent_loop", "runner_executor_public_id"),
      "the relayed process_log is addressed to the one runner"
    assert_equal({ "name" => "process_log", "input" => { "id" => "p9", "lines" => 2 }, "key" => "relay",
                   "timeout_ms" => Rho::Extensions::Processes::Remote::TIMEOUT_MS },
      api.loop_creates.first.dig("agent_loop", "steps", 0, "tool"))

    store.remember(Rho::Host::Conversation.new(public_id: "c-2"), workspace: "ws-1", runner: "0199-k")
    several = request(daemon, :get, "/processes/log?id=p9&lines=2", token: token)
    assert_equal "404", several.code
    assert_equal({ "code" => "process_not_found", "message" => "no process p9 here; name a runner's table with --runner" },
      JSON.parse(several.body).fetch("error"), "two remote runners: no inference, the flag is named")
    assert_equal 1, api.loop_creates.length, "nothing relayed: the door refused before asking either runner"
  end

  # A runner-mode daemon follows no host: its own table alone, no relay.
  def test_a_runner_mode_daemon_lists_its_own_table_alone
    daemon = boot(config: runner_mode)
    document = JSON.parse(request(daemon, :get, "/processes", token: bearer(daemon)).body)
    assert_equal({ "processes" => [], "orphans" => [], "unreachable" => [] }, document)
  end

  private

    def group_gone?(pgid)
      Process.kill(0, -pgid)
      false
    rescue Errno::ESRCH
      true
    rescue Errno::EPERM
      false
    end
end
