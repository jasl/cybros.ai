require_relative "rho_conversation_test"

class RhoConversationTest
  # ---- THE CONVERSATION'S ENVIRONMENT — E1, the root ----

  # NO KERNEL FIELD: the environment is rho's OWN record in the conversation's `store_entries` —
  # namespace `rho.environment`, key `binding/<Runner UUID>`, value `{root, directories, anchor}` exactly, nothing
  # else riding it — written by the host only when a verb NAMES a root set, read by every turn.
  # `rho-dev do --dir` BINDS (today's flag described): two conversations on two directories, their
  # says interleaved — each relative `write` lands under its own root, no 409 (each verb succeeds),
  # `rho-dev environments` lists both, each lead names its root. The record reads through the SDK at
  # `lock_version 0`; `rho-dev environment ID --also D` is ONE write (`1`) and the next lead carries
  # `Additional directories:`; a say reads and never writes. A SIDE is born with the kernel's fork
  # copy — its own public id, `lock_version 0`, the parent's tuple and anchor — and its relative
  # `read` reads the parent's root. A LEAD IS LAID ONCE PER WINDOW: a say lays its lead only when it
  # differs from the one its history carries, so the second say on an unchanged root lays none and
  # the root-set change lays one beside it. Every script here speaks its remainder (`reply: true`)
  # and each lead pin reads the say's own sealed request, whose newest lead is its own or the
  # identical one it carries.
  def test_two_conversations_bound_to_their_own_directories_write_under_them_and_a_side_reads_the_parents_root
    connect!
    dir_a = bound_directory("a")
    dir_b = bound_directory("b")
    marker_a = "hello from A #{SecureRandom.hex(4)}"
    marker_b = "hello from B #{SecureRandom.hex(4)}"
    conversation_a, _turn_a, loop_a = open_turn(script([note("note.txt", marker_a)], "wrote a", reply: true), dir_a)
    conversation_b, _turn_b, loop_b = open_turn(script([note("note.txt", marker_b)], "wrote b", reply: true), dir_b)
    await_run_status(loop_a, "completed")
    await_run_status(loop_b, "completed")
    assert_equal "#{marker_a}\n", File.read(File.join(dir_a, "note.txt"), encoding: Encoding::UTF_8),
      "A's relative write landed under A's root"
    assert_equal "#{marker_b}\n", File.read(File.join(dir_b, "note.txt"), encoding: Encoding::UTF_8),
      "B's relative write landed under B's root"
    assert_lead_names(loop_a, dir_a)
    assert_lead_names(loop_b, dir_b)

    # INTERLEAVED: the second say on each — the mock counts the answers
    # already in the history, so each script is padded by one.
    loop_a2 = rho_say_loop(conversation_a, script([note("again.txt", marker_a)] * 2, "again a", reply: true))
    loop_b2 = rho_say_loop(conversation_b, script([note("again.txt", marker_b)] * 2, "again b", reply: true))
    await_run_status(loop_a2, "completed")
    await_run_status(loop_b2, "completed")
    assert_equal "#{marker_a}\n", File.read(File.join(dir_a, "again.txt"), encoding: Encoding::UTF_8)
    assert_equal "#{marker_b}\n", File.read(File.join(dir_b, "again.txt"), encoding: Encoding::UTF_8)
    assert_lead_names(loop_a2, dir_a)
    assert_lead_names(loop_b2, dir_b)
    assert_equal 1, lead_count(loop_a2, "r1"),
      "the lead is laid once per window: the second say on the same root reads turn 1's and lays none"

    listing, status = @daemon.cli("environments")
    assert_predicate status, :success?, "rho-dev environments failed:\n#{listing}"
    [[conversation_a, dir_a], [conversation_b, dir_b]].each do |conversation, dir|
      line = listing.lines.find { |candidate| candidate.include?(conversation) }
      refute_nil line, "rho-dev environments lists #{conversation}:\n#{listing}"
      assert_includes line, dir, "and names its root:\n#{listing}"
    end

    record = binding_record(conversation_a)
    assert_equal 0, record.lock_version, "one bind at the open: the row's first version"
    assert_equal({ "root" => dir_a, "directories" => [], "anchor" => conversation_a }, record.value,
      "the compared tuple IS the value; nothing else rides it")

    dir_d = bound_directory("d")
    printed, status = @daemon.cli("environment", conversation_a, "--also", dir_d)
    assert_predicate status, :success?, "rho-dev environment --also failed:\n#{printed}"
    assert_includes printed, dir_d, "the verb prints the root set it wrote:\n#{printed}"
    record = store(conversation_a).fetch(record.public_id)
    assert_equal 1, record.lock_version, "one --also, one write: read-compare-write under the last-read version"
    assert_equal({ "root" => dir_a, "directories" => [dir_d], "anchor" => conversation_a }, record.value)
    door = @daemon.control(:get, "/conversations/environment?public_id=#{conversation_a}").fetch("environment")
    assert_equal [dir_a, [dir_d], conversation_a, 1], door.values_at("root", "directories", "anchor", "lock_version"),
      "the daemon's read is the record, fresh: #{door.inspect}"
    assert_equal "conversation", door.fetch("source"), door.inspect

    loop_a3 = rho_say_loop(conversation_a, script([note("third.txt", marker_a)] * 3, "third a", reply: true))
    await_run_status(loop_a3, "completed")
    assert_equal "#{marker_a}\n", File.read(File.join(dir_a, "third.txt"), encoding: Encoding::UTF_8)
    assert_lead_names(loop_a3, dir_a)
    assert_match(/Additional directories:.*#{Regexp.escape(dir_d)}/, sealed_words(loop_a3, "r1"),
      "the lead names the rest of the root set")
    assert_equal 2, lead_count(loop_a3, "r1"), "a changed root set is a new lead, laid beside the one carried"
    assert_equal 1, store(conversation_a).fetch(record.public_id).lock_version, "a say reads the record and never writes"

    # THE SIDE: the kernel's fork copy, then its read under the parent's root.
    opened, status = @daemon.cli("side", conversation_a)
    assert_predicate status, :success?, "rho side failed:\n#{opened}"
    side_id = opened[/^side:\s+(\S+)/, 1]
    refute_nil side_id, opened
    copy = binding_record(side_id)
    refute_equal record.public_id, copy.public_id, "the fork's copy is a row of its own"
    assert_equal 0, copy.lock_version, "born at zero"
    assert_equal record.value, copy.value, "the parent's tuple, the parent's anchor"
    side_loop = rho_say_loop(side_id, script([["read", { "path" => "note.txt" }]] * 4, "read it", reply: true))
    row = await_run_status(side_loop, "completed")
    read = row.fetch("tasks").find { |task| task["tool_name"] == "read" }
    refute_nil read, "the side never called read: #{summarize(row)}"
    assert_equal "completed", read.fetch("status"), read.inspect
    assert_includes tool_result(side_loop, read.fetch("key")), marker_a, "the side's relative read reads the parent's root"
  end

  # A SPAWNED CHILD INHERITS THE PARENT'S ROOT: the kernel copies nothing at spawn. On the host's
  # own runner the upward walk at the dispatch resolves the child by its parent
  # (`conversation(child).fetch.parent`), so the child's relative `write` lands under the parent's
  # root, and the child's OWN copy of the record appears in its store with the parent's anchor — the
  # host's top-down copy at the child edge, or the walk's; `key_taken` → done either way.
  def test_a_spawned_childs_write_lands_under_the_parents_root_and_its_copy_carries_the_parents_anchor
    connect!
    dir_a = bound_directory("parent")
    marker = "from the child #{SecureRandom.hex(4)}"
    brief = script([note("child.txt", marker)], "child done")
    conversation, _turn, loop = open_turn(script([["spawn", { "prompt" => brief, "label" => "helper" }]], "parent done"), dir_a)
    chat = steward_client.workspace(@workspace_public_id).conversation(conversation)
    child = await("no child labelled helper under #{conversation}", every: FEED_POLL) do
      chat.children.items.find { |row| row.parent&.label == "helper" }
    end
    child_chat = steward_client.workspace(@workspace_public_id).conversation(child.public_id)
    assert_equal conversation, child_chat.fetch.parent.public_id, "the child names its parent"
    await_completed_reply(child_chat)

    assert_equal "#{marker}\n", File.read(File.join(dir_a, "child.txt"), encoding: Encoding::UTF_8),
      "the child's relative write landed under the PARENT's root"
    parent_record = binding_record(conversation)
    copy = binding_record(child.public_id)
    refute_equal parent_record.public_id, copy.public_id, "the child's copy is a row of its own"
    assert_equal({ "root" => dir_a, "directories" => [], "anchor" => conversation }, copy.value,
      "the parent's tuple, the parent's anchor")
    await_run_status(loop, "completed")
  end

  # THE LAST WRITER WINS AND rho WRITES ONLY ON A NAMED ROOT SET: a second writer PATCHing the
  # record through the SDK between two `rho say`s — the next say's lead names the new root, its
  # write lands there, and `lock_version` is untouched by rho. A daemon RESTART empties the memo and
  # the next turn re-reads the store: the binding holds. `rho-dev environment ID <the rho checkout>`
  # is refused `protected_root` at the door, the record untouched (part 8 (2); the incubation denies
  # stand in every mode). ARCHIVE: `:host_ended` drops the live table's row and rho writes no delete
  # — the record stands, at the same version, until the kernel's cascade reaps it with the
  # conversation; the tombstone hides the row at once. Every script speaks its remainder
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
    await("the daemon never dropped the archived conversation from its live table", every: FEED_POLL) do
      listing, list_status = @daemon.cli("environments")
      assert_predicate list_status, :success?, listing
      listing.include?(conversation) ? nil : true
    end
    standing = store(conversation).fetch(record.public_id)
    assert_equal 1, standing.lock_version, "no delete written, no version moved: the reap is the kernel's cascade"
    chat.delete
    assert_raises(CybrosAgent::Api::NotFound, "the tombstone hides the record with the conversation") do
      store(conversation).fetch(record.public_id)
    end
  end

  # ---- THE FILE-SYSTEM PORT — E2 ----

  # THE EDITOR'S BUFFERS ARE WHAT read, edit AND write SEE (part 6, decisions
  # 13-17): the scripted loopback fs server stands in for the ACP surface;
  # `rho-dev port ID --endpoint --token --read --write` registers it through the
  # door's `fs:` member under the record's anchor. A `read` of a path under
  # the root set whose disk copy differs answers the UNSAVED BUFFER, windowed
  # (a limit is always sent) with the port-shaped footer and no total; the
  # lead of that turn carries the one conventions sentence while the port is
  # live. A `write` lands in the buffer and on the editor's disk (the
  # server's mirror) — never on rho's disk — and the result says it went
  # through the client. `edit` is gated on BOTH flags: registered read-only,
  # both halves go to the disk and the buffer stands; with both, the
  # pre-read is the buffer whole and the edit lands in the buffer and on
  # the editor's disk while rho's copy stands. A write the editor refuses
  # is the tool's is_error and nothing lands anywhere. A path outside the
  # root set is the disk's, the port never asked.
  def test_an_unsaved_buffer_is_read_through_the_port_a_write_and_an_edit_land_in_it_edit_needs_both_flags_and_a_refused_write_writes_nothing
    connect!
    dir = bound_directory("port")
    server = fs_server
    marker = "seeded #{SecureRandom.hex(4)}"
    conversation, _turn, loop = open_turn(script([note("seed.txt", marker)], "seeded", reply: true), dir)
    await_run_status(loop, "completed")
    await_follower(conversation, loop: loop)
    refute_includes sealed_words(loop, "r1"), PORT_SENTENCE, "no port yet: no sentence"

    register_port(conversation, server, "--read", "--write")
    draft = File.join(dir, "draft.txt")
    File.write(draft, "disk one\ndisk two\n", encoding: Encoding::UTF_8)
    server.set_buffer(draft, (1..5).map { |n| "buffer line #{n}" }.join("\n") + "\n")

    loop2 = rho_say_loop(conversation, script([["read", { "path" => "draft.txt", "limit" => 2 }]] * 2, "read it", reply: true))
    await_run_status(loop2, "completed")
    read = tool_result_of(loop2, "read")
    assert_includes read, "buffer line 1", "the unsaved buffer, not the disk:\n#{read}"
    assert_includes read, "buffer line 2"
    refute_includes read, "buffer line 3", "windowed by the limit"
    refute_includes read, "disk one", "the disk copy is not what read sees"
    assert_match(/Showing lines 1.2; more lines remain\. Use offset=3 to continue\./, read, "the port-shaped footer, no total")
    refute_match(/lines total/, read, "a buffer never crosses whole: no total")
    assert_includes sealed_words(loop2, "r1"), PORT_SENTENCE, "the sentence rides the lead while the port is live"
    assert_equal 1, server.requests.count { |request| request.path == "POST /fs/read" && request.body["path"] == draft }
    assert_equal({ "path" => draft, "line" => 1, "limit" => 3 }, server.requests.find { |request| request.path == "POST /fs/read" }.body,
      "the window: the offset and one line past the limit, to prove more remain")

    fresh = File.join(dir, "fresh.txt")
    text = "fresh #{SecureRandom.hex(4)}\n"
    loop3 = rho_say_loop(conversation, script([["write", { "path" => "fresh.txt", "content" => text }]] * 3, "wrote", reply: true))
    await_run_status(loop3, "completed")
    written = tool_result_of(loop3, "write")
    assert_includes written, "written through rho-dev", "the result names the client:\n#{written}"
    assert_equal text, server.buffers.fetch(fresh), "the write landed in the editor's buffer"
    assert_equal text, File.read(server.mirror_path(fresh), encoding: Encoding::UTF_8), "and on the editor's disk"
    refute File.exist?(fresh), "never on rho's disk: the port was asked"

    register_port(conversation, server, "--read")
    loop4 = rho_say_loop(conversation, script([["edit", { "path" => "draft.txt",
      "edits" => [{ "oldText" => "disk one", "newText" => "disk uno" }] }]] * 4, "edited", reply: true))
    await_run_status(loop4, "completed")
    edited = tool_result_of(loop4, "edit")
    refute_includes edited, "written through", "one flag: the whole edit is the disk's:\n#{edited}"
    assert_equal "disk uno\ndisk two\n", File.read(draft, encoding: Encoding::UTF_8), "the disk changed"
    assert_equal (1..5).map { |n| "buffer line #{n}" }.join("\n") + "\n", server.buffers.fetch(draft), "the buffer stands"
    assert_equal 1, server.requests.count { |request| request.path == "POST /fs/read" }, "no port read for a one-flag edit"
    assert_equal 1, server.requests.count { |request| request.path == "POST /fs/write" }, "no port write for a one-flag edit"

    # BOTH FLAGS (part 9: "edit lands in the buffer and the server's write
    # is observed"): the pre-read is the buffer WHOLE — `{path}` alone, no
    # line, no limit — the ladder runs over the buffer's text, the
    # write-back lands in the buffer and on the editor's disk, and rho's
    # disk copy stands untouched: the port was asked.
    register_port(conversation, server, "--read", "--write")
    loop5 = rho_say_loop(conversation, script([["edit", { "path" => "draft.txt",
      "edits" => [{ "oldText" => "buffer line 3", "newText" => "buffer line three" }] }]] * 5, "edited the buffer", reply: true))
    await_run_status(loop5, "completed")
    edited_buffer = tool_result_of(loop5, "edit")
    assert_includes edited_buffer, "Successfully replaced 1 block(s)", "the edit landed:\n#{edited_buffer}"
    expected = "buffer line 1\nbuffer line 2\nbuffer line three\nbuffer line 4\nbuffer line 5\n"
    assert_equal expected, server.buffers.fetch(draft), "the edit landed in the editor's buffer"
    assert_equal expected, File.read(server.mirror_path(draft), encoding: Encoding::UTF_8), "and on the editor's disk"
    assert_equal "disk uno\ndisk two\n", File.read(draft, encoding: Encoding::UTF_8), "rho's disk copy stands: the port was asked"
    port_reads = server.requests.select { |request| request.path == "POST /fs/read" }
    assert_equal 2, port_reads.length, "the window, then the pre-read"
    assert_equal({ "path" => draft }, port_reads.last.body, "the pre-read is the buffer whole: no line, no limit")
    port_writes = server.requests.select { |request| request.path == "POST /fs/write" }
    assert_equal 2, port_writes.length, "the write, then the edit's write-back"
    assert_equal expected, port_writes.last.body.fetch("text"), "the write-back carries the whole edited text"

    server.mode = "refuse"
    refused = File.join(dir, "refused.txt")
    loop6 = rho_say_loop(conversation, script([["write", { "path" => "refused.txt", "content" => "no\n" }]] * 6, "refused", reply: true))
    row = await_run_status(loop6, "completed")
    task = row.fetch("tasks").find { |candidate| candidate["tool_name"] == "write" }
    refute_nil task, summarize(row)
    assert_equal true, task.dig("result", "is_error"), "the editor's refusal is the tool's is_error: #{task.inspect}"
    assert_includes tool_result(loop6, task.fetch("key")), "rho-dev", "the error names the client"
    refute File.exist?(refused), "nothing on rho's disk"
    refute File.exist?(server.mirror_path(refused)), "nothing on the editor's"
    refute server.buffers.key?(refused), "nothing in the buffer"

    # OUTSIDE THE ROOT SET (part 6's routing table, its last row): the
    # disk, never a refusal, and the port is not asked — a buffer the
    # editor holds for a path outside the set is not what rho reads.
    server.mode = "serve"
    outside = File.join(bound_directory("outside"), "outside.txt") # a directory beside the set, never bound
    File.write(outside, "outside disk\n", encoding: Encoding::UTF_8)
    server.set_buffer(outside, "outside buffer\n")
    loop7 = rho_say_loop(conversation, script([["read", { "path" => outside }]] * 7, "read outside", reply: true))
    await_run_status(loop7, "completed")
    outside_read = tool_result_of(loop7, "read")
    assert_includes outside_read, "outside disk", "outside the root set: the disk\n#{outside_read}"
    refute_includes outside_read, "outside buffer", "the editor's buffer for a path outside the set is not read"
    assert_equal 2, server.requests.count { |request| request.path == "POST /fs/read" }, "the port is not asked outside the set"
  end

  # THE DROPS AND THE ANCHOR (part 6's error table, part 8 (3), decision
  # 16, decision 30): a SIDE and a SPAWNED CHILD read through the parent's
  # port — their bindings carry the parent's anchor, and the port is
  # keyed by it. The server gone: the next `read` is the DISK with one
  # notice, the port dropped (`fs_port.dropped` once), `rho-dev
  # environment` shows it off and the read after that is the disk with no
  # notice. Registered again and the server killed: a `write` is the
  # is_error and nothing lands on any disk (a write never falls to disk
  # after the port was asked). Registered once more and the conversation
  # archived: `:host_ended` drops it.
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
    loop2 = rho_say_loop(conversation, script([["spawn", { "prompt" => brief, "label" => "reader" }]] * 2, "spawned", reply: true))
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
    @daemon.await("the archived conversation's port was never dropped at :host_ended") do
      @daemon.log_lines.find { |line| line["event"] == "fs_port.dropped" && line["reason"] == "host_ended" && line["anchor"] == conversation }
    end
    assert_equal 3, @daemon.log_lines.count { |line| line["event"] == "fs_port.dropped" }
  end

  # THE EDITOR'S MCP SERVERS, PER CONVERSATION: `rho-dev environment ID --mcp FILE.json` hands the
  # mock world's http fixture — the ACP `mcpServers` shape, one http entry carrying a
  # credential-shaped header — to conversation A, and the server runs on the AGENT slot of this
  # daemon: the verb prints the row connected, the agent slot announces the fixture's seven names on
  # top of its own (the daemon's `executor.announced` line — the member plane cannot show an agent
  # address, `agent_announcements`), and A's scripted call is addressed to the agent application and
  # answered with the fixture's own text. THE SCOPE (part 7 "Scope", decision 19): every anchor's
  # `mcp__` extras are subtracted from a turn's names but the turn's own anchor's, so B's round is
  # never offered the name and B's call is the kernel's `unknown_tool` at birth — the sealed request
  # says which round carried the name. (The slot's own sentence, "belongs to conversation P's editor
  # and is not offered here", answers a call that reaches the slot from elsewhere — a remote agent
  # bound to this rho's runner, group 3's — which no local turn can make past the narrowing.) `rho
  # mcp` lists the row with its owner. The header's VALUE is the row's secret under rho-mcp's
  # per-row Redact (decision 20): never on the terminal, never in rho.log, never in the
  # announcement. C handing the SAME fixture under the same name is ONE announced entry serving two
  # connections: C's call runs, the name is announced once. An `sse` entry beside the http row is
  # FAULTED as a row — `down — transport sse unsupported` — and the http row beside it still runs (a
  # changed set is a re-list). `--mcp []` closes A's set: the verb prints no row, A's next call is
  # refused like B's (its own anchor holds no extra now) while the name stays announced for C; C's
  # close takes the name off the announcement and off `rho mcp`.
  def test_the_editors_mcp_servers_run_in_their_conversation_alone_list_with_their_owner_keep_the_secret_and_close
    write_settings!("plugins" => E2E::RhoDaemon::DEV_SETTINGS.fetch("plugins").merge("rho.mcp" => { "enabled" => true }))
    connect!
    url = mcp_fixture_url
    secret = E2E::SecretHygiene.register("s3cr3t-#{SecureRandom.hex(8)}")
    http_entry = { "type" => "http", "name" => "fx", "url" => url, "headers" => [{ "name" => "X-Secret", "value" => secret }] }
    servers = mcp_file("servers", [http_entry])
    dir_a, dir_b, dir_c = %w[a b c].map { |name| bound_directory("mcp-#{name}") }
    conversation_a, _turn_a, loop_a = open_turn(script([note("seed.txt", "seed a")], "seeded a", reply: true), dir_a)
    conversation_b, _turn_b, loop_b = open_turn(script([note("seed.txt", "seed b")], "seeded b", reply: true), dir_b)
    conversation_c, _turn_c, loop_c = open_turn(script([note("seed.txt", "seed c")], "seeded c", reply: true), dir_c)
    [[conversation_a, loop_a], [conversation_b, loop_b], [conversation_c, loop_c]].each do |conversation, loop|
      await_run_status(loop, "completed")
      await_follower(conversation, loop: loop)
    end

    # (a) THE BIND on A, and A's call: the agent slot's answer, the fixture's text.
    # n0 is the slot's own count (its placement's announcement, awaited);
    # the bind lands a NEW announcement of n0 + the fixture's seven.
    @daemon.await_announced(address: "agent")
    announced = agent_announcements
    n0 = announced.last
    printed = bind_servers(conversation_a, servers)
    assert_equal ["mcp:          fx  connected"], mcp_rows(printed), "one row, connected:\n#{printed}"
    refute_includes printed, secret, "the header's value never prints"
    announced = await_agent_announcement(announced.length, n0 + FIXTURE_TOOLS)
    loop_a2 = rho_say_loop(conversation_a, script([echo("hello from A")] * 2, "echoed a", reply: true))
    echoed = mcp_call(await_run_status(loop_a2, "completed"), "mcp__fx__echo")
    assert_equal "completed", echoed.fetch("status"), echoed.inspect
    assert_equal ["agent_application", rho_agent_id], echoed.fetch("addressed_to").values_at("role", "executor_public_id"),
      "the editor's server runs on this daemon's agent slot: #{echoed.inspect}"
    assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}hello from A", mcp_output(loop_a2, echoed.fetch("key")).strip,
      "the fixture's own answer"
    assert_includes declared_tool_names(loop_a2), "mcp__fx__echo", "A's frozen declaration carries its own editor's name"
    refute_includes sealed_tool_names(loop_a2), "mcp__fx__echo", "the MCP schema is loaded through discovery"
    await_follower(conversation_a, loop: loop_a2)

    # A writable Side keeps A's environment anchor and frozen tool authority.
    # Its first call follows the two tool answers in A's inherited history.
    opened = @daemon.control(:post, "/side", body: {
      "parent_public_id" => conversation_a,
      "text" => script([echo("hello from Side")] * 3, "echoed side", reply: true),
    })
    assert_equal "write", opened.fetch("tools"), opened.inspect
    side_id = opened.fetch("side").fetch("public_id")
    side_loop = opened.fetch("run").fetch("public_id")
    assert_equal binding_record(conversation_a).value, binding_record(side_id).value
    side_call = mcp_call(await_run_status(side_loop, "completed"), "mcp__fx__echo")
    assert_equal "completed", side_call.fetch("status"), side_call.inspect
    assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}hello from Side", mcp_output(side_loop, side_call.fetch("key")).strip
    assert_includes declared_tool_names(side_loop), "mcp__fx__echo"
    await_follower(side_id, loop: side_loop, side: true)

    # A later Side turn can use the same frozen MCP name through Code Mode.
    source = 'const answer = await tools.mcp__fx__echo({text: "hello from Side again"}); text(answer.content[0].text);'
    side_loop2 = rho_say_loop(side_id, script([["code", { "code" => source }]] * 4, "echoed side again", reply: true))
    side_row = await_run_status(side_loop2, "completed")
    code_call = mcp_call(side_row, "code")
    assert_equal "completed", code_call.fetch("status"), code_call.inspect
    side_call2 = mcp_call(side_row, "mcp__fx__echo")
    assert_equal "completed", side_call2.fetch("status"), side_call2.inspect
    assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}hello from Side again", mcp_output(side_loop2, side_call2.fetch("key")).strip
    assert_includes declared_tool_names(side_loop2), "mcp__fx__echo"
    await_follower(side_id, loop: side_loop2, side: true)
    [side_id, side_loop2].each do |public_id|
      watched, status = @daemon.cli("watch", public_id, "--timeout", "10")
      assert_predicate status, :success?, "rho watch on the Side failed:\n#{watched}"
      assert_match(/^status:\s+completed$/, watched)
    end

    # (b) B: the name is subtracted from its round, so the call is never offered.
    loop_b2 = rho_say_loop(conversation_b, script([echo("hello from B")] * 2, "echoed b", reply: true))
    refused = mcp_call(await_run_status(loop_b2, "completed"), "mcp__fx__echo")
    assert_equal %w[failed unknown_tool], [refused.fetch("status"), refused.dig("error", "key")],
      "A's editor's server is not offered to B: #{refused.inspect}"
    refute_includes declared_tool_names(loop_b2), "mcp__fx__echo", "B's declaration never carried the name"
    await_follower(conversation_b, loop: loop_b2)

    # (c) `rho mcp` lists the row with its owner; (d) the secret is nowhere.
    listed, status = @daemon.cli("mcp")
    assert_predicate status, :success?, "rho mcp failed:\n#{listed}"
    row = listed.lines.find { |line| line.start_with?("server:") && line.include?("fx") && line.include?(url) }
    refute_nil row, "rho mcp lists the conversation's server:\n#{listed}"
    assert_includes row, "connected", row
    assert_includes row, conversation_a, "with its owner:\n#{listed}"
    refute_includes listed, secret, "the header's value is masked on the terminal"
    refute_includes @daemon.log_text, secret, "the header's value never reaches rho.log"
    refute_includes sealed_tools(loop_a2).inspect, secret,
      "nor the announcement — the declarations the kernel holds for the announced names, as A's round received them"
    refute_includes declared_tools(loop_a2).inspect, secret, "nor the full frozen MCP declaration"

    # (f) C hands the same fixture under the same name: one entry serving two.
    printed = bind_servers(conversation_c, servers)
    assert_equal ["mcp:          fx  connected"], mcp_rows(printed), printed
    # A moved table re-announces; the same seven names from two anchors
    # count once — the slot's list is a union by name.
    announced = await_agent_announcement(announced.length, n0 + FIXTURE_TOOLS)
    loop_c2 = rho_say_loop(conversation_c, script([echo("hello from C")] * 2, "echoed c", reply: true))
    echoed_c = mcp_call(await_run_status(loop_c2, "completed"), "mcp__fx__echo")
    assert_equal "completed", echoed_c.fetch("status"), echoed_c.inspect
    assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}hello from C", mcp_output(loop_c2, echoed_c.fetch("key")).strip
    assert_equal 1, declared_tool_names(loop_c2).count("mcp__fx__echo"), "the same name and schema from two conversations is one entry"
    await_follower(conversation_c, loop: loop_c2)

    # (g) an sse entry beside the http row, on A: the row faulted, the http row runs.
    mixed = mcp_file("mixed", [http_entry, { "type" => "sse", "name" => "sx", "url" => url }])
    printed = bind_servers(conversation_a, mixed)
    assert_equal ["mcp:          fx  connected", "mcp:          sx  down — transport sse unsupported"], mcp_rows(printed), printed
    # The moved list is a re-boot of A's set and a re-announcement: a
    # faulted row announces nothing, so the count is the seven again.
    announced = await_agent_announcement(announced.length, n0 + FIXTURE_TOOLS)
    loop_a3 = rho_say_loop(conversation_a, script([echo("still A")] * 3, "still a", reply: true))
    still = mcp_call(await_run_status(loop_a3, "completed"), "mcp__fx__echo")
    assert_equal "completed", still.fetch("status"), still.inspect
    assert_equal "#{E2E::McpFixture::ECHO_TEXT_PREFIX}still A", mcp_output(loop_a3, still.fetch("key")).strip
    refute(declared_tool_names(loop_a3).any? { |name| name.start_with?("mcp__sx__") }, "a faulted row offers nothing")
    await_follower(conversation_a, loop: loop_a3)

    # (e) `--mcp []` closes A's set; C's close takes the name off the announcement.
    printed = bind_servers(conversation_a, MCP_CLOSE)
    refute_match(/^mcp:/, printed, "a closed set prints no row:\n#{printed}")
    # C still holds the name: the close re-announces, the entry stands.
    announced = await_agent_announcement(announced.length, n0 + FIXTURE_TOOLS)
    loop_a4 = rho_say_loop(conversation_a, script([echo("after the close")] * 4, "closed a", reply: true))
    gone = mcp_call(await_run_status(loop_a4, "completed"), "mcp__fx__echo")
    assert_equal %w[failed unknown_tool], [gone.fetch("status"), gone.dig("error", "key")], "A holds no extra now: #{gone.inspect}"
    refute_includes declared_tool_names(loop_a4), "mcp__fx__echo"
    printed = bind_servers(conversation_c, MCP_CLOSE)
    refute_match(/^mcp:/, printed, printed)
    # The last set gone: the slot announces its own count again.
    await_agent_announcement(announced.length, n0)
    listed, = @daemon.cli("mcp")
    refute(listed.lines.any? { |line| line.start_with?("server:") && line.include?(url) }, "nothing lists the closed fixture:\n#{listed}")
    refute_includes @daemon.log_text, secret
  end
end
