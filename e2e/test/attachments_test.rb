require "test_helper"
require "base64"
require "json"
require "net/http"
require "securerandom"
require "stringio"
require "support/actor_provisioning"
require "support/peer_program"
require "support/pdf_document"
require "support/red_square_png"
require "support/steward_session"

# ATTACHMENTS ON INPUTS, THROUGH A DEPLOYED SYSTEM. A staged PNG rides an input beside the words;
# what the model was SHOWN is read through the kernel's own door — the sealed request of the turn —
# never the mock's echo alone (the echo is the second witness, and a CONTAMINATED one for a later
# turn: turn 1's reply already carries `[image …]` and rides turn 2's history).
#
#   (1) THE VISION HALF on `dev/mock-text`: turn 1's sealed request holds
#       the `upload` part in the user entry and the echo holds
#       `[image image/png N bytes]` — a data URL left the process; turn 2
#       (no attachment) carries turn 1's picture in its history seed,
#       read off the sealed entries: a later turn sees the attachment.
#   (2) THE TEXT-ONLY HALF on a FRESH conversation on `dev/mock-text-only`:
#       the index line in the picture's position in the sealed entries,
#       no `upload` part, and no `[image` in that conversation's echo.
#   (6) THE COMPACTION HALF on a LOOP-BACKED turn: a peer program answers
#       (`E2E::PeerProgram`, one grant, its declaration a speaker's
#       engine under the kernel's compaction), turn 1 carries the picture
#       and reports `usage=9000:5` against the dev window, so the next
#       head arms the between-turn summary; the summarizer `k1`'s sealed
#       request carries the picture as a POINTER by filename and bytes —
#       never the upload id, never a data URL — and the turn after the cut
#       seals no `upload` part: the picture left the wire with the turns
#       the summary replaced.
#
# (3) PICTURE-ONLY, through the SDK (`inputs.create(kind: "direct_reply", attachments:)`, no words):
# the sealed user entry is exactly `[{upload}]`, no public id in any text part, the next turn's seed
# carries it — and the echo's byte count is the PREPARED VARIANT's (the kernel's own preparation of
# the upload, read through the operator), never the upload's. (4) PATCH KEEPS, through the SDK: a
# direct reply queued behind a held head (a scripted kernel `memory_ls` call parked for approval
# under the head's `ask`, released with the SDK's `deny`) is edited with `attachments` absent; the
# part rides the edited words into the turn's sealed request. A second queued reply clears its text
# with `""`; its sealed entry carries the kept picture alone. (5) THE STANDALONE LOOP's model step
# names `attachments` (the SDK's envelope passes the wire hash through) beside one scripted
# read-only kernel call (`memory_ls`), so the loop reaches a second round: both rounds seal the
# picture, the second's in its history, no id in any text. (8) THE STANDALONE QUEUE: a held loop
# accepts a picture beside words and a picture alone. Each queued input opens its own follow-up
# round, reaches the provider, and leaves the queue before completion. (7) THE REPRESENTATION READS,
# through the SDK: a 400 px picture's `thumbnail` is a PNG bounded at 256 on its longest edge
# (pinned by its header's dimensions, never byte for byte), its `preview` keeps the size; a text
# upload's thumbnail is the typed `representation_unavailable`; every read answers a strong ETag —
# one per kind — and a matching `etag:` is the typed `unchanged?` (304) with nothing written,
# another kind's tag a fresh 200.
#
# Rows (1)–(2) and (6) drive the door raw (the raw grammar is a door of its own); rows (3)–(5) are
# the SDK-driven form. No rho, no shared_human write; ONE ceremony per file (the steward's session
# and the peer's grant).
class AttachmentsTest < Minitest::Test
  VISION = "dev/mock-text".freeze
  DOCUMENT = E2E::CatalogOverlay::DOCUMENT_MODEL
  TEXT_ONLY = "dev/mock-text-only".freeze
  TURN_TIMEOUT = 120
  # 120 requests a minute per identity: polls are paced.
  POLL = 1.0
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )
  # The mock's second witness: the media type and the DECODED size of the
  # data URL it was handed. The wire carries the PREPARED variant (A.0/A.5:
  # the <=1600 px re-encode, `upload_media.rb:81`), so the count is the
  # image library's — 283 bytes for this 1x1 PNG under the harness's libvips,
  # never the upload's 70 — and is not pinned; only that bytes were decoded.
  ECHOED_PNG = %r{\[image image/png [1-9]\d* bytes\]}
  PEER_TOOL = {
    "type" => "function",
    "function" => { "name" => "note", "description" => "Keep a note",
                    "parameters" => { "type" => "object", "properties" => { "text" => { "type" => "string" } } } },
  }.freeze

  World = Struct.new(:steward, :actor, :room_public_id, :peer, keyword_init: true)

  class << self
    attr_reader :world

    # The steward's session, an account-wide room the peer can enter, and
    # the peer: declared once, a speaker's engine — its own `note` it never
    # calls, the kernel's memory family beside it (a declaration may alias
    # a kernel tool; the kernel serves it, so (4)'s scripted call reaches
    # the approval stage), `bypass`, the kernel's compaction.
    def boot_world!(base_url)
      provisioning = E2E::ActorProvisioning.world(base_url)
      steward = provisioning.rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      E2E.enable_dev_lane!
      E2E.hosts.start
      steward_client = CybrosAgent::Client.new(base_url: base_url, credential: steward.member_token)
      room = steward_client.workspaces.create(
        name: "Attachments #{SecureRandom.hex(3)}", access_mode: "account_wide", idempotency_key: SecureRandom.uuid
      ).workspace.public_id
      peer = E2E::PeerProgram.pair(base_url: base_url, actor: actor, name: "attachments-b")
      peer.client.profile.declare_configuration(
        tool_definitions: [PEER_TOOL] + kernel_memory_tools(steward_client), approval_mode: "bypass",
        approval_rules: nil, prompt_mechanism: "default", compaction_policy: { "mode" => "kernel" }
      )
      @world = World.new(steward: steward, actor: actor, room_public_id: room, peer: peer)
    end

    # The kernel's memory tools as the catalog declares them — executed
    # by the kernel itself, so a scripted call needs no runner.
    def kernel_memory_tools(client)
      client.tools.list.select { |entry| entry.canonical_name.start_with?("nexus.memory.") }.map(&:definition)
    end
  end

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @steward = @world.steward
    @room = @world.room_public_id
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @conversations = @client.workspace(@room).conversations
  end

  def teardown
    return if passed?

    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  end

  # (1) + (2): the part on a row that takes images, in the request and in
  # the next turn's history; the line on a row that cannot.
  def test_a_picture_rides_the_request_natively_or_as_the_index_line_and_a_later_turn_sees_it
    picture = stage_png("diagram.png")

    # ---- (1) THE VISION HALF ----
    chat = open_conversation("Vision half")
    first = ask(chat, "what is this?", model: VISION, attachments: [picture.public_id])
    sealed = sealed_request_of(chat, first)
    user_entry = sealed.entries.last
    assert_equal "user", user_entry.fetch("role")
    assert_equal %w[text upload], part_types(user_entry), "the words, then the picture, in the user entry"
    assert_equal picture.public_id, user_entry.dig("parts", 1, "upload_public_id")
    assert_equal "what is this?", user_entry.dig("parts", 0, "text")
    assert_match ECHOED_PNG, first.text.to_s,
      "the echo shows a data URL of the picture left the process: #{first.text.inspect}"
    refute_includes first.text.to_s, picture.public_id, "no upload id reaches the model"

    second = ask(chat, "and now?", model: VISION)
    later = sealed_request_of(chat, second)
    assert_equal "and now?", later.entries.last.dig("parts", 0, "text"), "turn 2's own words close the list"
    carried = later.entries[0...-1].flat_map { |entry| Array(entry["parts"]) }
      .select { |part| part["type"] == "upload" }
    assert_equal [picture.public_id], carried.map { |part| part["upload_public_id"] },
      "turn 1's picture rides turn 2's history seed, read through the door: #{later.entries.inspect}"

    # ---- (2) THE TEXT-ONLY HALF, a fresh conversation ----
    plain = open_conversation("Text-only half")
    lined = ask(plain, "what is this?", model: TEXT_ONLY, attachments: [picture.public_id])
    sealed = sealed_request_of(plain, lined)
    user_entry = sealed.entries.last
    assert_equal %w[text text], part_types(user_entry), "the line takes the picture's position as a text part"
    assert_equal index_line(picture), user_entry.dig("parts", 1, "text")
    refute sealed.entries.flat_map { |entry| Array(entry["parts"]) }.any? { |part| part["type"] == "upload" },
      "no upload part on a row that cannot take it"
    assert_includes lined.text.to_s, "this model does not support image input", "the model read the line"
    refute_includes lined.text.to_s, "[image", "no data URL left the process on this conversation"
    refute_includes lined.text.to_s, picture.public_id
  end

  def test_a_pdf_and_image_keep_their_order_and_pdf_history_follows_the_selected_models_capability
    bytes = E2E::PdfDocument.bytes
    pdf = @client.uploads.create_io(StringIO.new(bytes), filename: "report.dat")
    assert_equal ["report.pdf", "application/pdf", bytes.bytesize], [pdf.filename, pdf.content_type, pdf.byte_size]
    picture = stage_png("diagram.png")
    chat = open_conversation("Native PDF and image")

    first = ask(chat, "inspect both", model: DOCUMENT, attachments: [pdf.public_id, picture.public_id])
    entry = sealed_request_of(chat, first).entries.last
    assert_equal %w[text upload upload], part_types(entry)
    assert_equal [pdf.public_id, picture.public_id], upload_ids([entry])
    assert_equal [pdf.public_id, picture.public_id], first.active_variant.attachments.map(&:public_id)
    assert_includes first.text, "[file report.pdf application/pdf #{bytes.bytesize} bytes]"
    assert_match ECHOED_PNG, first.text
    refute_includes first.text, "base64"

    # The same retained prompt becomes a tool reference on an image-only row.
    second = ask(chat, "!mock echo=content -- inspect the earlier file", model: VISION)
    later = sealed_request_of(chat, second).entries
    assert_equal [picture.public_id], upload_ids(later)
    assert_includes texts_of(later).join("\n"), "nexus://uploads/#{pdf.public_id}"
    assert_includes texts_of(later).join("\n"), "file content is available through attachment tools"

    third = ask(chat, "!mock echo=content -- read the document again", model: DOCUMENT)
    assert_equal [pdf.public_id, picture.public_id], upload_ids(sealed_request_of(chat, third).entries)
  end

  def test_a_pdf_alone_is_native_and_an_unsupported_pdf_remains_a_tool_reference
    bytes = E2E::PdfDocument.bytes
    pdf = @client.uploads.create_io(StringIO.new(bytes), filename: "document.pdf")
    chat = open_conversation("Document only")
    chat.inputs.create(kind: "direct_reply", attachments: [pdf], model: DOCUMENT,
      idempotency_key: SecureRandom.uuid)
    reply = await_reply(chat, after: -1, what: "the document-only reply")
    entry = sealed_request_of(chat, reply).entries.last
    assert_equal %w[upload], part_types(entry)
    assert_equal [pdf.public_id], upload_ids([entry])
    assert_equal "Mock: [file document.pdf application/pdf #{bytes.bytesize} bytes]", reply.text

    plain = open_conversation("PDF through tools")
    fallback = ask(plain, "read this file", model: TEXT_ONLY, attachments: [pdf.public_id])
    sealed = sealed_request_of(plain, fallback).entries
    assert_empty upload_ids(sealed)
    assert_includes texts_of(sealed).join("\n"), "nexus://uploads/#{pdf.public_id}"
    refute_includes fallback.text, "[file "
  end

  # (6): the pointer in the summarizer's request, and the picture gone
  # from the wire after the cut.
  def test_a_compaction_summary_reads_the_picture_as_a_pointer_and_the_picture_leaves_the_wire_after_the_cut
    picture = stage_png("diagram.png")
    peer = @world.peer
    chat = open_conversation("Compaction half", answering_user_public_id: peer.public_id)

    # TURN 1, loop-backed: the picture beside the words, and a reported
    # usage past the dev window (8 192) that arms the next head's summary.
    first = ask(chat, "!mock usage=9000:5 -- describe the diagram", model: VISION,
      attachments: [picture.public_id])
    assert_equal peer.public_id, first.answering_user_public_id, "the peer answered: a loop-backed turn"
    loop_one = first.active_variant.run_public_id
    refute_nil loop_one, "a loop backs the peer's turn: #{first.to_h.inspect}"
    round_one = sealed_entries(loop_one, "r1")
    assert_equal [picture.public_id], upload_ids(round_one), "round one sealed the picture natively"

    # TURN 2 opens behind the between-turn summary. Its own `!mock --`
    # keeps the last marker line the turn's own (the summary carries turn
    # 1's line as the assistant's echoed words).
    second = ask(chat, "!mock -- what else?", model: VISION)
    compacted = feed(chat.public_id).select { |item| item["type"] == "context_compacted" }
    assert_equal 1, compacted.size, "exactly one repair on one wall: #{compacted.map { |c| c["payload"] }.inspect}"
    payload = compacted.first.fetch("payload")
    assert_equal %w[kernel usage], payload.values_at("mode", "trigger"), payload.inspect
    refute_nil payload["summary_turn_public_id"], "a summary turn between the two: #{payload.inspect}"

    # THE SUMMARIZER'S SEALED REQUEST: the one model task of the summary
    # turn's loop (`k1`; the between-turn payload names the loop, not the key).
    summary_loop = payload.fetch("run_public_id")
    summarizer_keys = loop_row(summary_loop).fetch("tasks").select { |task| task["kind"] == "model_task" }
      .map { |task| task.fetch("key") }
    assert_equal 1, summarizer_keys.length, "one model task in the summary loop: #{summarizer_keys.inspect}"
    summarizer_key = summarizer_keys.first
    handed = sealed_entries(summary_loop, summarizer_key)
    summarizer = texts_of(handed).join("\n")
    assert_includes summarizer, "describe the diagram\n#{pointer_line(picture)}",
      "the summarizer reads the picture as a pointer after the words: #{summarizer[0, 600].inspect}"
    refute_includes summarizer, picture.public_id, "a pointer names the picture, never its id"
    refute_includes summarizer, "data:image", "and never its bytes"
    assert_empty upload_ids(handed), "the summarizer's request seals no upload part"

    loop_two = second.active_variant.run_public_id
    after_cut = sealed_entries(loop_two, "r1")
    assert_empty upload_ids(after_cut), "after the cut the picture leaves the wire with the turns the summary replaced"
    assert_includes texts_of(after_cut).join("\n"), pointer_line(picture),
      "what remains of the picture is the summary's pointer"
    refute_includes texts_of(after_cut).join("\n"), picture.public_id
  end

  # (3): no words at all, the SDK's field; the bytes on the wire are the
  # prepared variant's.
  def test_a_picture_alone_is_the_whole_user_entry_and_the_wire_carries_the_prepared_variant
    picture = stage_png("diagram.png")
    chat = open_conversation("Picture only")
    inputs = chat.inputs
    # A `direct_reply`: the SDK's default kind is `message`, and a message
    # on a conversation nobody answers is never replied to.
    accepted = inputs.create(kind: "direct_reply", attachments: [picture], model: VISION,
      idempotency_key: SecureRandom.uuid)
    assert_equal [picture.public_id], Array(accepted.input.attachments).map(&:public_id), "the row names its picture"
    first = await_reply(chat, after: -1, what: "the picture-only message")
    sealed = sealed_request_of(chat, first)
    user_entry = sealed.entries.last
    assert_equal "user", user_entry.fetch("role")
    assert_equal %w[upload], part_types(user_entry), "the picture is the whole entry: #{user_entry.inspect}"
    assert_equal picture.public_id, user_entry.dig("parts", 0, "upload_public_id")
    refute_includes texts_of(sealed.entries).join("\n"), picture.public_id, "no id in any text part"

    # THE PIN: the echo names the DECODED size of the data URL on the wire —
    # the kernel's prepared variant of the upload (`UploadMedia.prepare`,
    # the Active Storage variant), read through the operator, and never
    # the upload's own 70 bytes.
    echoed = first.text.to_s[ECHOED_PNG]
    refute_nil echoed, "the echo shows a data URL of the picture left the process: #{first.text.inspect}"
    wire_bytes = Integer(echoed[/(\d+) bytes/, 1])
    prepared = E2E.operator.prepared_upload_bytes!(picture.public_id, VISION)
    assert_equal prepared, wire_bytes, "the wire carries the prepared variant's bytes"
    refute_equal picture.byte_size, wire_bytes, "never the upload's own bytes"

    second = ask(chat, "and now?", model: VISION)
    later = sealed_request_of(chat, second)
    carried = later.entries[0...-1].flat_map { |entry| Array(entry["parts"]) }.select { |part| part["type"] == "upload" }
    assert_equal [picture.public_id], carried.map { |part| part["upload_public_id"] }, "the next turn's seed carries it"
  end

  # (4): edits preserve the picture, beside new words or on its own.
  def test_pending_picture_edits_preserve_the_upload_and_can_remove_all_words
    picture = stage_png("diagram.png")
    peer = @world.peer
    chat = open_conversation("PATCH keeps", answering_user_public_id: peer.public_id)
    inputs = chat.inputs

    # THE HEAD IS HELD: a scripted call to a KERNEL-SERVED tool
    # (`memory_ls`) parks for approval under `approval_mode: "ask"` on a
    # `direct_reply` — the one kind that compiles a request, so the one
    # whose word can tighten the peer's `bypass`; the peer answers it as a
    # loop-backed turn, as (6) shows. Served, not announced: the peer's own
    # `note` has no executor, and "nobody serves it" is decided from
    # `queued` BEFORE the approval stage (`schedule_ready.rb`), so a call
    # to it fails instead of parking. No executor and no clock is waited on.
    hold = "!mock tool_call=memory_ls -- hold the line"
    inputs.create(kind: "direct_reply", text: hold, model: VISION, approval_mode: "ask",
      idempotency_key: SecureRandom.uuid)
    held_loop, parked_key = await("the hold's park") do
      turns = chat.turns.list.items.select { |row| row.role == "assistant" }
      turn = turns.max_by(&:position)
      loop_id = turn&.active_variant&.run_public_id
      @observed = { turns: turns.map { |row| [row.position, row.status] }, loop: loop_id }
      next nil if loop_id.nil?

      row = loop_row(loop_id)
      tasks = row.fetch("tasks")
      @observed[:approval_mode] = row["approval_mode"]
      @observed[:tasks] = tasks.map { |task| task.values_at("key", "status", "error_key", "error_detail") }
      parked = tasks.find { |task| task["status"] == "needs_approval" }
      parked && [loop_id, parked.fetch("key")]
    end

    # THE REQUEST BEHIND IT, with the picture; queued, then edited with
    # `attachments` absent. A `direct_reply`, as every ask in this file: a
    # `message` is what a speaker said, and nothing answers it by itself.
    queued = inputs.create(kind: "direct_reply", text: "what is this?", attachments: [picture.public_id],
      model: VISION, idempotency_key: SecureRandom.uuid).input
    assert_equal "pending", queued.state, "the message waits behind the held head: #{queued.to_h.inspect}"
    edited = inputs.update(queued.public_id, text: "what is THIS?")
    assert_equal "what is THIS?", edited.text
    assert_equal [picture.public_id], Array(edited.attachments).map(&:public_id), "an absent `attachments` keeps the row's picture"

    picture_only = inputs.create(kind: "direct_reply", text: "remove these words", attachments: [picture.public_id],
      model: VISION, idempotency_key: SecureRandom.uuid).input
    cleared = inputs.update(picture_only.public_id, text: "")
    assert_equal "", cleared.text, "an explicit empty string clears the queued words"
    assert_equal [picture.public_id], Array(cleared.attachments).map(&:public_id), "clearing text keeps the picture"

    # RELEASED: the park denied through the SDK, the head settles, the
    # edited message runs and seals.
    @client.workspace(@room).run(held_loop).tasks_context(parked_key).deny(reason: "not now")
    hold_position = chat.turns.list.items.select { |row| row.role == "assistant" }.map(&:position).min
    reply = await_reply(chat, after: hold_position, what: "the edited message")
    sealed = sealed_request_of(chat, reply)
    user_entry = sealed.entries.last
    assert_equal %w[text upload], part_types(user_entry), "the edited words, then the kept picture: #{user_entry.inspect}"
    assert_equal "what is THIS?", user_entry.dig("parts", 0, "text")
    assert_equal picture.public_id, user_entry.dig("parts", 1, "upload_public_id")

    picture_reply = await_reply(chat, after: reply.position, what: "the picture with its text removed")
    picture_entry = sealed_request_of(chat, picture_reply).entries.last
    assert_equal %w[upload], part_types(picture_entry), "no removed text enters the next turn: #{picture_entry.inspect}"
    assert_equal picture.public_id, picture_entry.dig("parts", 0, "upload_public_id")
  end

  # (5): the loop door's step names the picture; round two carries it.
  def test_a_standalone_loops_step_carries_the_picture_into_its_second_round
    picture = stage_png("diagram.png")
    loops = @client.workspace(@room).runs
    # The SDK's envelope passes a wire hash through (`Steps.envelope`):
    # `attachments` is the loop door's field beside the prompt. The scripted
    # call is READ-ONLY (`memory_ls`, no arguments): the kernel executes it
    # without a runner, and it leaves nothing behind — a `memory_write`
    # here rode into every later turn's memory block in this world.
    created = loops.create(
      steps: [{ "model" => { "model" => { "model" => VISION }, "tools" => kernel_memory_tools,
                             "prompt" => "!mock tool_call=memory_ls -- what is this?",
                             "attachments" => [picture.public_id] } }],
      approval_mode: "bypass", idempotency_key: SecureRandom.uuid
    )
    loop_id = created.run.public_id
    @client.workspace(@room).run(loop_id).start
    done = await("the loop's completion") do
      row = loop_row(loop_id)
      flunk "the loop failed: #{row.inspect}" if row["status"] == "failed"
      row if row["status"] == "completed"
    end
    # The step's root round is `s1-model-1` (the key the flat tools mint);
    # the round after the call is `r1`.
    rounds = done.fetch("tasks").select { |task| task["kind"] == "model_task" }.map { |task| task.fetch("key") }
    assert_equal %w[s1-model-1 r1], rounds, "one scripted call, two rounds: #{done.fetch("tasks").inspect}"

    round_one = sealed_entries(loop_id, "s1-model-1")
    assert_equal [picture.public_id], upload_ids(round_one), "round one seals the picture beside the prompt"
    round_two = sealed_entries(loop_id, "r1")
    assert_equal [picture.public_id], upload_ids(round_two), "round two carries it in its history"
    refute_includes texts_of(round_two).join("\n"), picture.public_id, "no id in any text"
    assert_includes texts_of(round_two).join("\n"), "what is this?", "the prompt is the words"
  end

  def test_a_standalone_loops_queued_pictures_reach_follow_up_rounds_with_or_without_text
    beside_words = stage_png("with-words.png")
    alone = stage_png("picture-only.png")
    workspace = @client.workspace(@room)
    created = workspace.runs.create(
      steps: [{ "model" => { "model" => { "model" => VISION }, "tools" => kernel_memory_tools,
                             "prompt" => "!mock tool_call=memory_ls -- hold for queued pictures" } }],
      approval_mode: "ask", idempotency_key: SecureRandom.uuid
    )
    loop_id = created.run.public_id
    running = workspace.run(loop_id)
    running.start
    parked = await("the standalone loop's approval park") do
      loop_row(loop_id).fetch("tasks").find { |task| task["status"] == "needs_approval" }
    end

    word = "look at the queued picture"
    first = running.inputs.create(text: word, attachments: [beside_words], delivery_mode: "queue",
      idempotency_key: SecureRandom.uuid)
    second = running.inputs.create(attachments: [alone], delivery_mode: "queue",
      idempotency_key: SecureRandom.uuid)
    assert_equal [first.public_id, second.public_id], running.inputs.list.items.map(&:public_id)
    running.tasks_context(parked.fetch("key")).deny(reason: "continue with the pictures")

    done = await("both queued pictures to complete their follow-up rounds") do
      row = loop_row(loop_id)
      @observed = row.slice("status", "input_queue", "tasks")
      flunk "the loop failed: #{row.inspect}" if row["status"] == "failed"
      row if row["status"] == "completed"
    end
    assert_empty running.inputs.list.items
    events = running.events(limit: 200).items
    landed = events.select { |event| event.type == "input_materialized" }
    assert_equal [first.public_id, second.public_id], landed.map { |event| event.payload.fetch("input_public_id") }
    assert_equal 2, landed.map { |event| event.payload.fetch("task_key") }.uniq.length,
      "each queued row gets a follow-up round"

    landed.zip([beside_words, alone]).each do |event, picture|
      task_key = event.payload.fetch("task_key")
      entries = sealed_entries(loop_id, task_key)
      assert_includes upload_ids(entries), picture.public_id, "the follow-up seals this queued picture"
      assert_match ECHOED_PNG, running.task(task_key).output.to_s, "the provider received image bytes"
    end
    first_entries = sealed_entries(loop_id, landed.first.payload.fetch("task_key"))
    assert_includes texts_of(first_entries).join("\n"), word
    settled = events.find { |event| event.type == "turn_status" && event.payload["status"] == "completed" }
    refute_nil settled
    assert_operator landed.last.sequence, :<, settled.sequence, "completion follows the last queued picture"
  ensure
    running&.stop(force: true) unless done
  end

  # (7): the two named reads, the typed refusal, the conditional GET.
  def test_a_pictures_thumbnail_and_preview_are_named_reads_with_one_tag_per_kind_and_a_text_upload_has_none
    wide = E2E::RedSquarePng.bytes(side: 400, square: 100..299)
    picture = @client.uploads.create_io(StringIO.new(wide), filename: "square.png")
    assert_equal "image/png", picture.content_type

    small = StringIO.new
    thumbnail = @client.uploads.thumbnail(picture.public_id, small)
    assert_equal 200, thumbnail.status
    assert_equal [256, 256], E2E::RedSquarePng.dimensions(small.string), "a smaller PNG: 256 on the longest edge"
    assert_operator small.string.bytesize, :<, wide.bytesize

    kept = StringIO.new
    preview = @client.uploads.preview(picture.public_id, kept)
    assert_equal 200, preview.status
    assert_equal [400, 400], E2E::RedSquarePng.dimensions(kept.string), "under the preview's bound the size is kept"

    whole = StringIO.new
    bytes = @client.uploads.bytes(picture.public_id, whole)
    assert_equal wide, whole.string.b, "the bytes read is the upload itself"

    tags = [bytes, thumbnail, preview].map(&:etag)
    tags.each { |tag| assert_match(/\A"[^"]+"\z/, tag.to_s, "a strong tag: #{tags.inspect}") }
    assert_equal 3, tags.uniq.length, "one upload, three kinds, three tags: #{tags.inspect}"

    nothing = StringIO.new
    again = @client.uploads.thumbnail(picture.public_id, nothing, etag: thumbnail.etag)
    assert_predicate again, :unchanged?, "a matching tag is the typed 304"
    assert_equal "", nothing.string, "nothing written on unchanged"
    assert_equal thumbnail.etag, again.etag
    assert_predicate @client.uploads.bytes(picture.public_id, StringIO.new, etag: bytes.etag), :unchanged?

    missed = StringIO.new
    crossed = @client.uploads.thumbnail(picture.public_id, missed, etag: bytes.etag)
    assert_equal 200, crossed.status, "another kind's tag misses"
    assert_equal [256, 256], E2E::RedSquarePng.dimensions(missed.string)

    # The kernel names a type by the BYTES ALONE (Marcel on the tempfile,
    # no name, `identify: false`): words with no magic are stored honestly
    # as the neutral type, never `text/plain` off the `.txt` — the SDK
    # declares octet-stream on every part for the same reason.
    note = @client.uploads.create_io(StringIO.new("plain words"), filename: "notes.txt")
    assert_equal "application/octet-stream", note.content_type, "bytes nothing recognizes: the byte detector's own word"
    refused = assert_raises(CybrosAgent::Api::NotFound) { @client.uploads.thumbnail(note.public_id, StringIO.new) }
    assert_equal "representation_unavailable", refused.code, "a text upload has no thumbnail: the typed refusal"
    assert_equal "representation_unavailable",
      assert_raises(CybrosAgent::Api::NotFound) { @client.uploads.preview(note.public_id, StringIO.new) }.code
    assert_equal 200, @client.uploads.bytes(note.public_id, StringIO.new).status, "its bytes still read"
  end

  private

    def kernel_memory_tools = self.class.kernel_memory_tools(@client)

    # The settled assistant turn past `after`, through the SDK; a failed
    # one fails HERE with its row.
    def await_reply(chat, after:, what:)
      await("a reply to #{what}") do
        turns = chat.turns.list.items
        newer = turns.select { |turn| turn.position > after && turn.role == "assistant" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed
        @observed = { turns: turns.map { |turn| [turn.position, turn.role, turn.status] },
                      tasks: loop_tasks_of(turns.select { |turn| turn.role == "assistant" }.max_by(&:position)) }
        newer.find { |turn| turn.status == "completed" }
      end
    end

    # The newest assistant turn's loop tasks, for a loud timeout.
    def loop_tasks_of(turn)
      loop_id = turn&.active_variant&.run_public_id
      return nil if loop_id.nil?

      loop_row(loop_id).fetch("tasks").map { |task| task.values_at("key", "status", "error_key") }
    end

    def stage_png(filename)
      upload = @client.uploads.create_io(StringIO.new(PNG), filename: filename)
      assert_equal "image/png", upload.content_type, "the bytes decide the type"
      assert_equal PNG.bytesize, upload.byte_size
      upload
    end

    def open_conversation(title, **fields)
      @conversations.conversation(
        @conversations.create(title: title, idempotency_key: SecureRandom.uuid, **fields).public_id
      )
    end

    # Raw input carries `attachments` beside `text` under `input`. The helper returns the settled
    # reply turn.
    def ask(chat, text, model:, attachments: nil)
      after = chat.turns.list.items.map(&:position).max || -1
      body, status = post_input(chat, { "kind" => "direct_reply", "text" => text, "model" => { "model" => model },
                                        "attachments" => attachments }.compact)
      assert_equal 202, status, "the input door refused: #{body.inspect}"
      await("a reply to #{text.inspect}") do
        newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed
        newer.find { |turn| turn.status == "completed" }
      end
    end

    def post_input(chat, input)
      uri = URI.join(@base_url, "/agent_api/v1/workspaces/#{@room}/conversations/#{chat.public_id}/inputs")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      request["Content-Type"] = "application/json"
      request["Idempotency-Key"] = SecureRandom.uuid
      request.body = JSON.generate("input" => input)
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      [JSON.parse(response.body.to_s.empty? ? "{}" : response.body.force_encoding(Encoding::UTF_8)), response.code.to_i]
    end

    # THE DEBUG DOOR: the active candidate's sealed request, off the deck.
    def sealed_request_of(chat, turn)
      deck = chat.turns.variants(turn.public_id)
      chat.turns.request(turn.public_id, deck.active.public_id)
    end

    def part_types(entry) = Array(entry["parts"]).map { |part| part["type"] }

    def index_line(upload)
      "[Attachment: #{upload.filename} (image/png, #{delimited(upload.byte_size)} bytes) — " \
        "image content omitted: this model does not support image input]"
    end

    def pointer_line(upload)
      "[Attachment: #{upload.filename} (image/png, #{delimited(upload.byte_size)} bytes) — " \
        "not carried past the summary; ask for it again if needed]"
    end

    def delimited(number) = number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

    # ---- the member plane, as the steward: a loop's sealed rounds ----

    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def loop_row(loop)
      document = agent_api("/agent_api/v1/workspaces/#{@room}/runs/#{loop}")
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def sealed_entries(loop, task_key)
      document = agent_api("/agent_api/v1/workspaces/#{@room}/runs/#{loop}/tasks/#{task_key}/request")
      entries = document.dig("request", "entries")
      refute_nil entries, "round #{task_key} of #{loop} has no sealed request: #{document.inspect}"
      entries
    end

    def upload_ids(entries)
      entries.flat_map { |entry| entry.is_a?(Hash) ? Array(entry["parts"]) : [] }
        .select { |part| part["type"] == "upload" }.map { |part| part["upload_public_id"] }
    end

    # Every string on the wire EXCEPT an `upload` part's own id field: the
    # part names its upload by public id (that is the wire's bookkeeping),
    # and "no id in any text" asks whether the id reached the model as words.
    def texts_of(value)
      case value
      when String then [value]
      when Array then value.flat_map { |item| texts_of(item) }
      when Hash then value.except("upload_public_id").values.flat_map { |item| texts_of(item) }
      else []
      end
    end

    def feed(conversation)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{@room}/conversations/#{conversation}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    def await(what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      loop do
        result = begin
          yield
        rescue CybrosAgent::Api::RateLimited => throttle
          flunk("the journey tripped the API's own rate limit (Retry-After #{throttle.retry_after}s)")
        end
        return result if result
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          seen = @observed ? " (last seen: #{@observed.inspect})" : ""
          flunk("the deployment never reached #{what}#{seen}")
        end

        sleep POLL
      end
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{tail}"
    end
end
