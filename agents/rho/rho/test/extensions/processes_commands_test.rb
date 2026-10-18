require "test_helper"

# The processes a run started, as the person drives them: listed, killed
# and read, against scripted daemons whose listing changes under the poll.
class ProcessesCommandsTest < Minitest::Test
  include RhoTest::CliHarness

  def processes(verb, *args, **options) = Rho::Extensions::Processes::Commands.public_send(verb, cli, args, options)

  def process_row(id, status, **extra)
    {
      "id" => id, "name" => "web", "command" => "python3 -m http.server", "workdir" => "/srv/app",
      "owner" => "conv-1", "run_public_id" => "run-a", "pid" => 4242, "status" => status, "exit_status" => nil, "signal" => nil,
      "ready_line" => "Listening on :3000", "log_path" => "/home/.rho/log/processes/#{id}.log",
    }.merge(extra)
  end

  def test_processes_lists_the_live_rows_and_what_a_dead_daemon_left
    announce(endpoint: routed_endpoint(
      "GET /processes" => [[200, {
        "processes" => [process_row("p1", "running")],
        "orphans" => [{ "id" => "p7", "pid" => 4, "command" => "old server" }],
      }]]
    ))

    rows = processes(:processes)

    assert_equal ["p1"], rows.map { |row| row["id"] }
    assert_match(/^p1  running  pid 4242  owner conv-1  run run-a  web  \(\/srv\/app\)\n    Listening on :3000$/, @out.string)
    assert_match(/reaped at start, left by a previous daemon: p7 pid 4 old server/, @out.string)
  end

  def test_processes_says_when_there_are_none
    announce(endpoint: routed_endpoint("GET /processes" => [[200, { "processes" => [], "orphans" => [] }]]))

    assert_empty processes(:processes)
    assert_match(/\(no processes\)/, @out.string)
  end

  # A group that died leaves the listing; the final line is read from the exit the daemon
  # remembers behind the log door.
  def test_kill_signals_then_follows_the_listing_to_the_end
    announce(endpoint: routed_endpoint(
      "POST /processes/stop" => [[202, { "process" => process_row("p1", "stopping") }]],
      # The log door first: the scripted table matches by prefix.
      "GET /processes/log" => [[200, { "process" => process_row("p1", "exited", "signal" => "TERM"), "lines" => [] }]],
      "GET /processes" => [
        [200, { "processes" => [process_row("p1", "stopping")] }],
        [200, { "processes" => [] }],
      ]
    ))

    row = processes(:kill, "p1", deadline: 5)

    assert_equal "exited", row["status"]
    assert_match(/\Ap1  exited \(signal TERM\)  pid 4242  owner conv-1  run run-a  web/, @out.string)
  end

  # The exit memory is bounded: a kill whose corpse was already forgotten
  # still ends with an exited line, from the last row it saw.
  def test_kill_ends_on_the_last_row_when_the_exit_is_no_longer_remembered
    announce(endpoint: routed_endpoint(
      "POST /processes/stop" => [[202, { "process" => process_row("p1", "stopping") }]],
      "GET /processes/log" => [[404, { "error" => { "code" => "process_not_found", "message" => "no process p1" } }]],
      "GET /processes" => [[200, { "processes" => [] }]]
    ))

    row = processes(:kill, "p1", deadline: 5)

    assert_equal "exited", row["status"]
    assert_match(/\Ap1  exited \(status -\)  pid 4242/, @out.string)
  end

  def test_kill_reports_an_unknown_process_as_the_daemon_said_it
    announce(endpoint: routed_endpoint(
      "POST /processes/stop" => [[404, { "error" => { "code" => "process_not_found", "message" => "no process p9" } }]]
    ))

    error = assert_raises(Rho::ConnectionError) { processes(:kill, "p9") }

    assert_includes error.message, "no process p9"
  end

  def test_logs_prints_the_row_the_path_and_the_tail
    announce(endpoint: routed_endpoint(
      "GET /processes/log?id=p1&lines=2" => [[200, {
        "process" => process_row("p1", "running"), "path" => "/home/.rho/log/processes/p1.log",
        "lines" => ["GET /hello.txt 200", "GET /missing 404"],
      }]]
    ))

    processes(:logs, "p1", tail: 2)

    assert_match(%r{^log: /home/.rho/log/processes/p1.log\nGET /hello.txt 200\nGET /missing 404$}, @out.string)
  end

  # THE ROWS ELSEWHERE: a row of a followed host's runner prints
  # ending in its runner; a runner that could not answer is one line; the
  # verb narrows to one table with --runner.
  def test_processes_prints_the_rows_of_runners_elsewhere_and_who_could_not_answer
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /processes" => [[200, {
        "processes" => [process_row("p1", "running"), process_row("p4", "running", "runner" => "0199-h")],
        "orphans" => [], "unreachable" => [{ "runner" => "0199-k", "error" => "tool_timeout" }],
      }]]
    ))

    processes(:processes, runner: "0199-h")

    lines = @out.string.lines.map(&:chomp)
    assert_match(/\Ap1  running/, lines.first)
    assert_match(/\Ap4  running  pid 4242  owner conv-1  run run-a  web  \(\/srv\/app\)  runner 0199-h\z/, lines[2])
    assert_equal "runner 0199-k could not answer: tool_timeout", lines.last
    assert(seen.any? { |req| req.start_with?("GET /processes?runner=0199-h") }, "the flag narrows the read: #{seen.inspect}")
  end

  def test_logs_names_the_runner_whose_table_holds_the_id
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /processes/log" => [[200, { "process" => process_row("p4", "running", "runner" => "0199-h"),
                                       "path" => "/there/p4.log", "lines" => ["GET / 200"] }]]
    ))

    processes(:logs, "p4", tail: 1, runner: "0199-h")

    assert(seen.any? { |req| req.start_with?("GET /processes/log?id=p4&lines=1&runner=0199-h") }, seen.inspect)
    assert_match(%r{runner 0199-h\n    Listening on :3000\nlog: /there/p4.log\nGET / 200}, @out.string)
  end
end
