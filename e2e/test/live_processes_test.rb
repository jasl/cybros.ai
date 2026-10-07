require "test_helper"
require "support/live_journey"
require "net/http"
require "socket"

# A BACKGROUND TASK, BY THE OWNER'S DEFINITION: the model starts a dev
# server the person can see and stop. The model's half is start_process
# and a fetch through it; the person's half is `rho processes`, `rho
# logs` and `rho kill` — and the server must be gone after the kill, with
# its port free, which no listing can prove and a connection attempt can.
#
# AND THE LIFECYCLE FOLLOWS THE CONVERSATION (item P): the entry is owned
# by the conversation and shows the loop; after the kill a second turn's
# `read_process` reads the exit and "the entry is gone", and its restart
# is a NEW id; archiving the conversation — the kernel's `conversation_ended`
# item, the end as a persisted event (2026-09-10) — kills that server and
# empties the table, the log file keeping the exit fact, and the
# conversation's next turn after the unarchive reads that end.
#
# WHAT THE RUNS FOUND: on both models every clause held — turn 1 `start_process` ×1 + `bash` ×1 (the
# fetch), every claim on the runner address; the person's `processes` / `logs` / `kill`, the port
# refusing after the kill; turn 2 `read_process` ×1 + `start_process` ×1 — the dead call's first
# line named the exit and "the entry is gone", the restart a NEW id; the archive's
# `conversation_ended` killed that server and emptied the table with the exit kept in the log; turn
# 3 after the unarchive `read_process` ×1 — the answer named the conversation's end.
# deepseek-v4.1-flash — 48 assertions, 39 s. glm-5.3-flash — 48 assertions, 64 s. Two lane repairs
# on the way, neither the kernel's or rho's: the dead-call regex of turn 2 now allows the label the
# model gives its server (deepseek named it "static file server", so the answer reads `p1 (static
# file server) exited …`, the form the turn-3 clause already allowed); and turn 3's SDK input is
# `kind: direct_reply` — the door's default `message` materialised a person turn and opened no
# reply, and the first paid run sat the full 900 s behind it (the mock lane's re-cut had the same
# fix).
#
# Paid, local, opt-in: E2E_LIVE=1; run once per flash model (E2E_LIVE_MODEL).
class LiveProcessesTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  CONTENT = "hello from the project #{SecureRandom.hex(4)}\n".freeze
  GONE = /exited with signal TERM, stopped by the person; the entry is gone — start_process again gives a new id\./
  ENDED = /exited with signal TERM, stopped when its conversation ended here; the entry is gone — start_process again gives a new id\./

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-procs-e2e")
  def teardown = finish_live_journey!

  def test_a_model_starts_a_server_the_person_can_see_read_and_kill
    connect_and_open_lane!
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    File.write(File.join(project, "hello.txt"), CONTENT)
    @daemon.control(:post, "/environment", body: { root: project })
    port = free_port

    task = <<~TEXT.strip
      Start a static file server for this directory on port #{port} using the
      start_process tool (`python3 -m http.server #{port}` works; pass
      wait_for "Serving HTTP"). Once it is serving, fetch
      http://127.0.0.1:#{port}/hello.txt with bash (curl -s) and reply with
      exactly the file's contents, nothing else. Leave the server running —
      do not stop it.
    TEXT
    output, status = @daemon.cli("do", task, "--model", MODEL, "--dir", project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    loop_id = output[/^run:\s+(\S+)/, 1]
    conversation = output[/^conversation:\s+(\S+)/, 1]
    refute_nil conversation, output

    done = await_loop_completion(loop_id)
    report(done)
    assert_equal "completed", done.fetch("status"), summarize(done)
    tools = done.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
    started = tools.find { |t| t["tool_name"] == "start_process" }
    refute_nil started, "the model never called start_process: #{tools.map { |t| t["tool_name"] }.inspect}"
    assert_equal "completed", started.fetch("status")
    # WHICH ADDRESS SERVED IT (r-modes M1): a full-mode rho runs its
    # environment tools on its RUNNER row, and the claim line says so —
    # every claim this daemon logged carries `address=runner`, none the
    # agent's, on a real model.
    claims = @daemon.claims
    refute_empty claims, "the daemon's runner logged no claim"
    assert_includes claims.map { |claim| claim["tool"] }, "start_process", claims.inspect
    assert_equal %w[runner], claims.map { |claim| claim["address"] }.uniq,
      "the environment tools ran on the runner address alone: #{claims.inspect}"

    # THE MODEL'S HALF: it read the file through the server it started.
    result, = @daemon.cli("result", loop_id)
    assert_includes result, CONTENT.strip

    # THE PERSON'S HALF: the server is listed, owned by the CONVERSATION
    # with the loop beside it (item P), still answering on its port, its
    # log reachable and under HOME.
    listing, = @daemon.cli("processes")
    assert_match(/^p\d+  running  pid \d+  owner #{Regexp.escape(conversation)}  run #{Regexp.escape(loop_id)}/, listing, listing)
    id = listing[/^(p\d+)  running/, 1]
    assert_equal CONTENT, Net::HTTP.get(URI("http://127.0.0.1:#{port}/hello.txt"))

    logs, = @daemon.cli("logs", id)
    assert_match(%r{^log: #{Regexp.escape(@home)}/.*log/processes/#{id}\.log$}, logs, logs)
    assert_match(%r{GET /hello\.txt}, logs, "the fetch went through the server's log")
    refute File.exist?(File.join(project, "artifacts")), "nothing of ours lands in the project"

    killed, = @daemon.cli("kill", id)
    assert_match(/^#{id}  exited \(signal TERM\)/, killed, killed)
    assert_raises(Errno::ECONNREFUSED) { Net::HTTP.get(URI("http://127.0.0.1:#{port}/hello.txt")) }

    # THE DEAD CALL, ON A REAL MODEL (item P): turn 2 of the same
    # conversation reads the killed id — the answer names the exit and
    # says the entry is gone — and restarts the server under a NEW id.
    said, status = @daemon.cli("say", conversation, <<~TEXT.strip)
      Call read_process on process #{id} first and quote its answer's first line verbatim.
      Then start the same static file server again on port #{port} with start_process
      (wait_for "Serving HTTP"), leave it running, and reply with the new process id.
    TEXT
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    loop_two = await_next_loop(conversation, after: loop_id)
    second = await_loop_completion(loop_two)
    report(second)
    assert_equal "completed", second.fetch("status"), summarize(second)
    read = second.fetch("tasks").find { |t| t["kind"] == "tool_task" && t["tool_name"] == "read_process" }
    refute_nil read, "the model never called read_process: #{summarize(second)}"
    assert_match(/\A#{id}( \([^)]*\))? #{GONE}/, task_output(loop_two, read.fetch("key")),
      "the dead call names the exit, with the label the model gave the server or without one")
    restarted = second.fetch("tasks").find { |t| t["kind"] == "tool_task" && t["tool_name"] == "start_process" }
    refute_nil restarted, "the model never restarted the server: #{summarize(second)}"
    new_id = task_output(loop_two, restarted.fetch("key"))[/\A(p\d+) \(pid \d+\) running/, 1]
    refute_nil new_id, "the restart is a running process"
    refute_equal id, new_id, "the old id never revives"
    listing, = @daemon.cli("processes")
    assert_match(/^#{new_id}  running  pid \d+  owner #{Regexp.escape(conversation)}  run #{Regexp.escape(loop_two)}/, listing, listing)
    assert_equal CONTENT, Net::HTTP.get(URI("http://127.0.0.1:#{port}/hello.txt"))

    # THE CONVERSATION ENDS HERE: archived under the daemon's follow — the
    # kernel's `conversation_ended` item is what the daemon's socket hears
    # — the server is killed, the entry removed, the port free, the exit kept.
    chat = sdk_workspace.conversations.conversation(conversation)
    refute_nil chat.archive.archived_at, "archive answers the archived row"
    await_listing_without(new_id)
    assert_raises(Errno::ECONNREFUSED) { Net::HTTP.get(URI("http://127.0.0.1:#{port}/hello.txt")) }
    logs, = @daemon.cli("logs", new_id)
    assert_match(/^#{new_id}  exited \(signal TERM\)  pid \d+  owner #{Regexp.escape(conversation)}/, logs, logs)
    assert_match(/^\[rho\] #{new_id}( \([^)]*\))?: leader exited with signal TERM, stopped when its conversation ended here; the group ended at /, logs, logs)

    # THE DEAD CALL AFTER THE END, ON A REAL MODEL: unarchived, the
    # conversation's next turn (through the SDK — the daemon forgot the
    # host; its runner answers the row all the same) reads the id it left
    # running, and the answer names the conversation's end.
    refute_nil chat.unarchive, "unarchive answers the row"
    # `kind: direct_reply`: the door's default is a `message` turn, which
    # opens no reply (the mock lane's idiom; the first paid run of this
    # clause sat 900 s behind a person turn no assistant turn followed).
    chat.inputs.create(kind: "direct_reply", text: <<~TEXT.strip, model: MODEL, idempotency_key: SecureRandom.uuid)
      Call read_process on process #{new_id} and quote its answer's first line verbatim.
      Do not start anything.
    TEXT
    loop_three = await_next_loop(conversation, after: [loop_id, loop_two])
    third = await_loop_completion(loop_three)
    report(third)
    assert_equal "completed", third.fetch("status"), summarize(third)
    read = third.fetch("tasks").find { |t| t["kind"] == "tool_task" && t["tool_name"] == "read_process" }
    refute_nil read, "the model never called read_process after the end: #{summarize(third)}"
    assert_match(/\A#{new_id}( \([^)]*\))? #{ENDED}/, task_output(loop_three, read.fetch("key")),
      "the dead call names the conversation's end")
  end

  private

    def sdk_workspace
      @sdk_workspace ||= CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
        .workspace(workspace_public_id)
    end

    # The next assistant turn's loop on the conversation, once minted: the
    # one not among the loops already seen (`after`, one id or many).
    def await_next_loop(conversation, after:, deadline: LOOP_DEADLINE_SECONDS)
      known = Array(after)
      chat = sdk_workspace.conversations.conversation(conversation)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        found = chat.turns.list.items.filter_map { |turn| turn.active_variant&.run_public_id }
          .find { |loop_id| !known.include?(loop_id) }
        return found if found
        raise "the next turn never started on #{conversation}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 3
      end
    end

    def await_listing_without(id, deadline: 30)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        listing, = @daemon.cli("processes")
        return listing unless listing.match?(/^#{id}  /)
        flunk "the conversation's end never ended #{id}:\n#{listing}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 1
      end
    end

    def task_output(loop_id, key)
      agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop_id}/tasks/#{key}")
        .dig("task", "output").to_s
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def report(row)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live processes --------------------------------------------"
      puts "model:   #{MODEL}"
      puts "status:  #{row.fetch("status")}"
      puts "calls:   #{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")}"
      puts "--------------------------------------------------------------"
    end
end
