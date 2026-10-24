require_relative "rho_conversation_test"

class RhoConversationTest
  def test_git_review_feedback_reaches_the_original_conversation_through_an_ordinary_input
    connect!
    directory = bound_directory("review")
    assert system("git", "-C", directory, "init", "-q")
    File.write(File.join(directory, "example.rb"), "committed behavior\n")
    assert system("git", "-C", directory, "add", ".")
    assert system("git", "-C", directory, "-c", "user.name=Review", "-c", "user.email=review@example.test", "commit", "-qm", "baseline")
    File.write(File.join(directory, "example.rb"), "old behavior\n")
    conversation, turn, run = open_turn(script([note("example.rb", "new behavior")], "Updated", reply: true), directory)
    await_run_status(run, "completed")
    assert system("git", "-C", directory, "add", ".")
    assert system("git", "-C", directory, "-c", "user.name=Review", "-c", "user.email=review@example.test", "commit", "-qm", "finished")
    turns = @daemon.control(:get, "/conversations/turns?public_id=#{conversation}").fetch("turns")
    variant = turns.find { |row| row.fetch("public_id") == turn }.dig("active_variant", "public_id")
    path = "/conversations/review?public_id=#{conversation}&turn=#{turn}&variant=#{variant}"
    review = @daemon.control(:get, path, expected_status: 200).fetch("reviews").first
    refute_nil review, "the completed write retained its review after Git commit"
    assert_equal File.realpath(directory), review.fetch("root")
    assert_includes review.fetch("files").first.fetch("patch"), "-old behavior\n+new behavior"
    refute_includes review.fetch("files").first.fetch("patch"), "-committed behavior"
    comment = review.slice("runner", "root", "base").merge(
      "path" => "example.rb", "side" => "left", "line" => 1, "excerpt" => "old behavior",
      "turn" => turn, "variant" => variant, "run" => run, "text" => "Please retain the original behavior")
    feedback = @daemon.control(:post, "/conversations/review/feedback", body: { public_id: conversation, comment: comment }, expected_status: 200).fetch("text")
    File.write(File.join(directory, "example.rb"), "changed again\n")
    assert_equal review, @daemon.control(:get, path, expected_status: 200).fetch("reviews").first
    body = { public_id: conversation, text: feedback, approval_mode: "ask", delivery_mode: "queue", idempotency_key: SecureRandom.uuid }
    accepted = @daemon.control(:post, "/say", body: body, expected_status: 200)
    replay = @daemon.control(:post, "/say", body: body, expected_status: 200)
    assert_equal accepted.dig("input", "public_id"), replay.dig("input", "public_id")
    loop_id = accepted.fetch("run").fetch("public_id")
    await_run_status(loop_id, "completed")
    words = sealed_words(loop_id, "r1")
    assert_includes words, feedback
    assert_equal "old behavior", JSON.parse(feedback.split("\n", 2).last).fetch("excerpt")
  end

  # ---- THE CONVERSATION'S ENVIRONMENT — E1, the root ----

  # THE LAST WRITER WINS AND rho WRITES ONLY ON A NAMED ROOT SET: a second writer PATCHing the
  # record through the SDK between two `rho say`s — the next say's lead names the new root, its
  # write lands there, and `lock_version` is untouched by rho. A daemon RESTART empties the memo and
  # the next turn re-reads the store: the binding holds. `rho-dev environment ID <the rho checkout>`
  # is refused `protected_root` at the door, the record untouched (part 8 (2); the incubation denies
  # stand in every mode). Archive retains the environment for accepted work. Tombstoning fires
  # `:host_ended` and drops the live table's row; rho writes no store delete. The record stands
  # at the same version until the kernel's cascade reaps it; the tombstone hides it at once.
  # Every script speaks its remainder
  # (`reply: true`), so the lead pins on the second and third say read those says' own sealed
  # requests: the second lays the new root's lead, and the third — the same root — reads it carried.
  def test_a_second_writers_patch_reaches_the_next_say_the_binding_survives_a_restart_and_archive_leaves_the_record_to_the_cascade
    connect!
    dir_a = bound_directory("first")
    dir_c = bound_directory("second")
    marker = "moved #{SecureRandom.hex(4)}"
    conversation, _turn, loop = open_turn(script([note("one.txt", marker)], "one", reply: true), dir_a)
    await_run_status(loop, "completed")
    await_follower(conversation, loop: loop)
    assert_equal "#{marker}\n", File.read(File.join(dir_a, "one.txt"), encoding: Encoding::UTF_8)
    record = binding_record(conversation)
    assert_equal 0, record.lock_version

    patched = store(conversation).update(record.public_id,
      value: { "root" => dir_c, "directories" => [], "anchor" => conversation }, lock_version: record.lock_version)
    assert_equal 1, patched.lock_version, "the person's PATCH is the second write"
    loop2 = rho_say_loop(conversation, script([note("two.txt", marker)] * 2, "two", reply: true))
    await_run_status(loop2, "completed")
    assert_equal "#{marker}\n", File.read(File.join(dir_c, "two.txt"), encoding: Encoding::UTF_8),
      "the next say's write landed under the root the person set"
    refute File.exist?(File.join(dir_a, "two.txt")), "and nothing under the old one"
    assert_lead_names(loop2, dir_c)
    assert_equal 1, store(conversation).fetch(record.public_id).lock_version, "rho read the edit and wrote nothing"
    await_follower(conversation, loop: loop2)

    restart_daemon!
    printed, status = @daemon.cli("environment", conversation)
    assert_predicate status, :success?, "rho-dev environment failed after the restart:\n#{printed}"
    assert_includes printed, dir_c, "the memo rebuilt from the store:\n#{printed}"
    loop3 = rho_say_loop(conversation, script([note("three.txt", marker)] * 3, "three", reply: true))
    await_run_status(loop3, "completed")
    assert_equal "#{marker}\n", File.read(File.join(dir_c, "three.txt"), encoding: Encoding::UTF_8),
      "the binding holds over the restart"
    assert_lead_names(loop3, dir_c)
    assert_equal 1, store(conversation).fetch(record.public_id).lock_version
    await_follower(conversation, loop: loop3)

    refused, status = @daemon.cli("environment", conversation, E2E::RhoDaemon::RHO_ROOT)
    refute_predicate status, :success?, "a protected root must be refused at the door:\n#{refused}"
    assert_includes refused, "is under a protected root", "the door's 422 protected_root, as the verb relays it:\n#{refused}"
    assert_equal({ "root" => dir_c, "directories" => [], "anchor" => conversation },
      store(conversation).fetch(record.public_id).value, "the record is untouched by a refusal")

    chat = steward_client.workspace(@workspace_public_id).conversation(conversation)
    assert_predicate chat.archive, :archived?
    await_environment_archive_read(conversation, chat.events.watermark)
    listing, list_status = @daemon.cli("environments")
    assert_predicate list_status, :success?, listing
    assert_includes listing, conversation, "archive preserves the environment for accepted work"
    standing = store(conversation).fetch(record.public_id)
    assert_equal 1, standing.lock_version, "no delete written, no version moved: the reap is the kernel's cascade"
    chat.delete
    await("the daemon never dropped the deleted conversation from its live table", every: FEED_POLL) do
      listing, list_status = @daemon.cli("environments")
      assert_predicate list_status, :success?, listing
      listing.include?(conversation) ? nil : true
    end
    assert_raises(CybrosAgent::Api::NotFound, "the tombstone hides the record with the conversation") do
      store(conversation).fetch(record.public_id)
    end
  end

  # ---- THE FILE-SYSTEM PORT — E2 ----

  # THE DROPS AND THE ANCHOR (part 6's error table, part 8 (3), decision
  # 16, decision 30): a SIDE and a SPAWNED CHILD read through the parent's
  # port — their bindings carry the parent's anchor, and the port is
  # keyed by it. The server gone: the next `read` is the DISK with one
  # notice, the port dropped (`fs_port.dropped` once), `rho-dev
  # environment` shows it off and the read after that is the disk with no
  # notice. Registered again and the server killed: a `write` is the
  # is_error and nothing lands on any disk (a write never falls to disk
  # after the port was asked). Registered once more and the conversation
  # archived: the port remains for accepted work. Tombstoning fires `:host_ended` and drops it.
  def test_a_side_and_a_child_read_through_the_parents_port_and_the_port_drops_on_unavailable_and_at_host_ended
    connect!
    dir = bound_directory("anchor")
    server = fs_server
    conversation, _turn, loop = open_turn(script([note("seed.txt", "seed")], "seeded", reply: true), dir)
    await_run_status(loop, "completed")
    await_follower(conversation, loop: loop)
    register_port(conversation, server, "--read", "--write")
    shared = File.join(dir, "shared.txt")
    File.write(shared, "from the disk\n", encoding: Encoding::UTF_8)
    server.set_buffer(shared, "from the editor's buffer\n")
    reads_of_shared = -> { server.requests.count { |request| request.path == "POST /fs/read" && request.body["path"] == shared } }

    opened, status = @daemon.cli("side", conversation)
    assert_predicate status, :success?, "rho side failed:\n#{opened}"
    side_id = opened[/^side:\s+(\S+)/, 1]
    refute_nil side_id, opened
    side_loop = rho_say_loop(side_id, script([["read", { "path" => "shared.txt" }]] * 2, "read it", reply: true))
    await_run_status(side_loop, "completed")
    assert_includes tool_result_of(side_loop, "read"), "from the editor's buffer", "the side reads through the parent's port"
    assert_equal 1, reads_of_shared.call

    brief = script([["read", { "path" => "shared.txt" }]], "child done", reply: true)
    loop2 = rho_say_loop(conversation, script([["spawn", { "role" => "worker", "prompt" => brief, "label" => "reader" }]] * 2, "spawned", reply: true))
    chat = steward_client.workspace(@workspace_public_id).conversation(conversation)
    child = await("no child labelled reader under #{conversation}", every: FEED_POLL) do
      chat.children.items.find { |candidate| candidate.parent&.label == "reader" }
    end
    await_completed_reply(steward_client.workspace(@workspace_public_id).conversation(child.public_id))
    await_run_status(loop2, "completed")
    assert_equal 2, reads_of_shared.call, "the child's read went through the parent's port by the anchor"
    assert_equal({ "root" => dir, "directories" => [], "anchor" => conversation }, binding_record(child.public_id).value)
    # THE CHILD'S REPLY WAKES THE PARENT (the spawn path): a `spawn` is detached, the reply is
    # mailed to the parent and drains at loop2's boundary into a turn of its own, so the follower's
    # row moves on to the woken loop and never rests on loop2 — the wait is on the woken turn. Its
    # marker is loop2's line, whose two calls are already answered (the seed's write, the spawn), so
    # it speaks and spends nothing on the clock: loop3's script is padded as before.
    woken = await_feed(conversation, "the child's reply never woke the parent") do |items|
      new_turns(items, except: [loop, loop2]).first
    end
    woken_loop = woken.dig("payload", "run_public_id")
    await_run_status(woken_loop, "completed")
    await_follower(conversation, loop: woken_loop)

    server.mode = "die"
    loop3 = rho_say_loop(conversation, script([["read", { "path" => "shared.txt" }]] * 3, "read again", reply: true))
    await_run_status(loop3, "completed")
    read = tool_result_of(loop3, "read")
    assert_includes read, "from the disk", "the port gone: the disk\n#{read}"
    refute_includes read, "from the editor's buffer"
    dropped = @daemon.log_lines.select { |line| line["event"] == "fs_port.dropped" }
    assert_equal 1, dropped.length, "dropped once: #{dropped.inspect}"
    assert_equal [conversation, "unavailable"], dropped.fetch(0).values_at("anchor", "reason")
    printed, status = @daemon.cli("environment", conversation)
    assert_predicate status, :success?, printed
    assert_includes printed, "fs:           off", "the verb shows no port:\n#{printed}"
    await_follower(conversation, loop: loop3)

    loop4 = rho_say_loop(conversation, script([["read", { "path" => "shared.txt" }]] * 4, "read once more", reply: true))
    await_run_status(loop4, "completed")
    again = tool_result_of(loop4, "read")
    assert_includes again, "from the disk"
    refute_includes again, "rho-dev", "no notice on a read after the drop:\n#{again}"
    refute_includes newest_lead_words(loop4, "r1"), PORT_SENTENCE, "the sentence left with the port: this turn's lead"
    assert_equal 1, @daemon.log_lines.count { |line| line["event"] == "fs_port.dropped" }
    await_follower(conversation, loop: loop4)

    second = fs_server
    register_port(conversation, second, "--read", "--write")
    printed, = @daemon.cli("environment", conversation)
    assert_includes printed, "fs:           on — rho-dev (read, write)", printed

    # A WRITE NEVER FALLS TO DISK AFTER THE PORT WAS ASKED (decision 16,
    # part 12): the second server killed with its port still registered →
    # the write is the tool's is_error saying nothing was written, nothing
    # on rho's disk, nothing on the editor's, and the port dropped once more.
    second.mode = "die"
    lost = File.join(dir, "lost.txt")
    loop5 = rho_say_loop(conversation, script([["write", { "path" => "lost.txt", "content" => "lost\n" }]] * 5, "lost", reply: true))
    row = await_run_status(loop5, "completed")
    task = row.fetch("tasks").find { |candidate| candidate["tool_name"] == "write" }
    refute_nil task, summarize(row)
    assert_equal true, task.dig("result", "is_error"), "the port did not confirm: the tool's is_error: #{task.inspect}"
    assert_includes tool_result(loop5, task.fetch("key")), "nothing was written"
    refute File.exist?(lost), "never on rho's disk after the port was asked"
    refute File.exist?(second.mirror_path(lost)), "nothing on the editor's"
    assert_equal 2, @daemon.log_lines.count { |line| line["event"] == "fs_port.dropped" && line["reason"] == "unavailable" }
    await_follower(conversation, loop: loop5)

    third = fs_server
    register_port(conversation, third, "--read", "--write")
    assert_predicate chat.archive, :archived?
    await_environment_archive_read(conversation, chat.events.watermark)
    printed, status = @daemon.cli("environment", conversation)
    assert_predicate status, :success?, printed
    assert_includes printed, "fs:           on — rho-dev (read, write)", "archive keeps the port for accepted work"
    assert_equal 2, @daemon.log_lines.count { |line| line["event"] == "fs_port.dropped" }
    chat.delete
    @daemon.await("the deleted conversation's port was never dropped at :host_ended") do
      @daemon.log_lines.find { |line| line["event"] == "fs_port.dropped" && line["reason"] == "host_ended" && line["anchor"] == conversation }
    end
    assert_equal 3, @daemon.log_lines.count { |line| line["event"] == "fs_port.dropped" }
  end

  private

    def await_environment_archive_read(conversation, sequence)
      @daemon.await("the follower never consumed the conversation's archive") do
        row = @daemon.control(:get, "/followers").fetch("followers").find { |entry| entry.fetch("public_id") == conversation }
        row if row && row.fetch("sequence") >= sequence
      end
    end
end
