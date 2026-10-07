require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiConversationInputsTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def test_create_reads_replay_from_the_header_while_preserving_the_accepted_status
    fixture = contract.fetch("valid_input_fixture")
    first = chat([[202, { "Idempotency-Replayed" => "false" }, fixture]]).inputs.create(
      text: "Continue", idempotency_key: "input-1"
    )
    refute_predicate first, :replayed?

    replayed = chat([[202, { "IDEMPOTENCY-REPLAYED" => "true" }, fixture]]).inputs.create(
      text: "Continue", idempotency_key: "input-1"
    )
    assert_predicate replayed, :replayed?
    assert_equal first.input, replayed.input
  end

  def test_the_estimate_is_write_free_and_reports_compaction_apart_from_trimming
    estimate = chat([[200, {}, contract.fetch("valid_estimate_fixture")]]).estimate_input(
      model: "dev/text", prompt: "What is next?",
      history: { "max_entries" => 20 }
    )

    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/context_estimate", request.fetch(:path)
    assert_equal({ "model" => "dev/text" },
      request.fetch(:body).fetch("context_estimate").fetch("model"))
    assert_equal 812, estimate.input_tokens
    assert_predicate estimate, :tokenizer_exact?
    assert_predicate estimate.history, :trimmed?
    assert_predicate estimate.history, :compacted?
    assert_equal 9, estimate.history.compacted,
      "summarized history is CARRIED; skipped history is not — never one number"
  end

  # THE PREVIEW IS THE ESTIMATE RENDERED (one door): `render:
  # true` asks for the bytes the send would seal, `to:` names the
  # addressee the compile runs under (the input door's own word),
  # `variables:` the turn's values and `template:` an estimate-only trial
  # order — all four on the same POST body. The answer's rendered half
  # reads as typed evidence: the entries as frozen snapshots (a debug
  # read's whole value is the bytes), the storage line against the seal's
  # bound, one block row per template block, memory and the slot versions.
  def test_the_rendered_estimate_reads_the_preview_and_sends_the_four_preview_fields
    template = { "blocks" => [{ "type" => "history" }, { "type" => "input" }] }
    estimate = chat([[200, {}, contract.fetch("valid_rendered_estimate_fixture")]]).estimate_input(
      model: "dev/text", prompt: "and this question", render: true, to: "@narrator",
      variables: { "scene" => "a rainy night" }, template: template
    )

    body = request.fetch(:body).fetch("context_estimate")
    assert_equal true, body.fetch("render"), "a JSON boolean, never a string"
    assert_equal "@narrator", body.fetch("answering_user_public_id"), "`to:` is the door's own word"
    assert_equal({ "scene" => "a rainy night" }, body.fetch("variables"))
    assert_equal template, body.fetch("template")

    assert_predicate estimate, :rendered?
    rendered = estimate.rendered
    assert_equal "assembly", rendered.mechanism
    fixture = contract.dig("valid_rendered_estimate_fixture", "context_estimate")
    assert_equal fixture.fetch("entries"), rendered.entries, "the entries verbatim"
    assert_predicate rendered.entries, :frozen?
    assert_equal %w[system user], rendered.entries.map { |entry| entry["role"] }
    assert_equal contract.fetch("rendered_estimate_mechanisms").sort, %w[assembly default],
      "the two words a compile can run under"

    storage = rendered.storage
    assert_equal fixture.dig("storage", "bytes"), storage.bytes
    assert_equal fixture.dig("storage", "bound"), storage.bound
    assert_predicate storage, :within_bound?
    assert_nil storage.refusal, "within the bound there is no refusal member"

    keys = rendered.blocks.map(&:block)
    assert_equal fixture.fetch("blocks").map { |row| row["block"] }, keys, "one row per block, in template order"
    history = rendered.blocks.find { |row| row.type == "history" }
    assert_equal [3, "user", "selected", 3, 99_991],
      [history.index, history.role, history.state, history.tokens, history.allocated_tokens]
    assert_predicate history, :selected?
    memory_row = rendered.blocks.find { |row| row.type == "memory" }
    assert_predicate memory_row, :empty?
    assert_nil memory_row.role, "a block that rendered nothing has no role"
    # The `skills` block: the default order's fifth
    # block, a type like memory — empty here, a row all the same.
    skills_row = rendered.blocks.find { |row| row.type == "skills" }
    assert_equal ["skills", 2], [skills_row.block, skills_row.index]
    assert_predicate skills_row, :empty?
    refute rendered.blocks.any?(&:floor_unmet?)
    assert_equal contract.fetch("rendered_estimate_block_states").sort, %w[carried empty floor_unmet selected]
    assert_predicate history.with(block: "lead", type: "lead", state: "carried"), :carried?,
      "a lead the window already carries reads by its own word"

    assert_equal [0, 0], [rendered.memory.included, rendered.memory.omitted]
    assert_equal({ "system_prompt" => 4 }, rendered.slots, "R-28: the registered documents compiled, by slot")
    assert_equal 812, estimate.input_tokens, "the count rides beside the bytes"
  end

  # A storage line over the seal's bound still answers 200: the refusal
  # word rides beside the number, and a block the window could not fund
  # reads `floor_unmet` — evidence, never a byte change.
  def test_the_rendered_estimate_reports_the_overflow_and_an_unfunded_floor
    fixture = contract.fetch("valid_rendered_estimate_fixture")
    over = fixture.dig("context_estimate", "storage").merge(
      "bytes" => 2_000_000, "within_bound" => false, "refusal" => "content_too_large"
    )
    blocks = fixture.dig("context_estimate", "blocks").map do |row|
      row["block"] == "slot:system_prompt" ? row.merge("state" => "floor_unmet", "allocated_tokens" => 0) : row
    end
    body = { "context_estimate" => fixture.fetch("context_estimate").merge("storage" => over, "blocks" => blocks) }
    estimate = chat([[200, {}, body]]).estimate_input(model: "dev/text", render: true)

    refute_predicate estimate.rendered.storage, :within_bound?
    assert_equal "content_too_large", estimate.rendered.storage.refusal
    unmet = estimate.rendered.blocks.find(&:floor_unmet?)
    assert_equal "slot:system_prompt", unmet.block
    refute_predicate unmet, :selected?
  end

  # Without `render` the answer is the count alone, and the SDK says so
  # with nil rather than an empty envelope; nothing about the four preview
  # fields reaches the wire unless named.
  def test_an_unrendered_estimate_carries_no_preview_and_names_none_of_its_fields
    estimate = chat([[200, {}, contract.fetch("valid_estimate_fixture")]]).estimate_input(
      model: "dev/text", prompt: "What is next?"
    )

    body = request.fetch(:body).fetch("context_estimate")
    assert_equal %w[model prompt], body.keys.sort
    refute_predicate estimate, :rendered?
    assert_nil estimate.rendered
    refute estimate.to_h.key?(:rendered), "the count's own shape, unchanged"
  end

  # The turn's values for the addressee's declared template names ride the
  # input beside `history` and `inline` — on the create and on the edit —
  # and come back on the row's `context_options` as the kernel stored them.
  def test_variables_ride_the_input_and_the_edit
    fixture = contract.fetch("valid_input_fixture")
    with_variables = { "input" => fixture.fetch("input").merge(
      "context_options" => { "variables" => { "scene" => "a rainy night" } }
    ) }
    accepted = chat([[202, {}, with_variables]]).inputs.create(
      kind: "direct_reply", text: "set the scene", model: "dev/text",
      variables: { "scene" => "a rainy night" }, idempotency_key: "k"
    )
    assert_equal({ "scene" => "a rainy night" }, request.fetch(:body).dig("input", "variables"))
    assert_equal({ "variables" => { "scene" => "a rainy night" } }, accepted.input.context_options)

    chat([[200, {}, with_variables]]).inputs.update("id", variables: { "scene" => "dawn" })
    assert_equal({ "scene" => "dawn" }, request.fetch(:body).dig("input", "variables"))

    chat([[202, {}, fixture]]).inputs.create(text: "x", idempotency_key: "k")
    refute request.fetch(:body).fetch("input").key?("variables"), "unnamed sends no field"
  end

  # A conversation that has never compacted sends no `compacted` member,
  # and the absence must read as zero rather than as a malformed response.
  def test_an_absent_compacted_count_reads_as_zero
    body = contract.fetch("valid_estimate_fixture")
    body = { "context_estimate" => body.fetch("context_estimate").merge(
      "history" => body.dig("context_estimate", "history").except("compacted")
    ) }
    estimate = chat([[200, {}, body]]).estimate_input(model: "dev/text")

    assert_equal 0, estimate.history.compacted
    refute_predicate estimate.history, :compacted?
  end

  # --- the input queue ------------------------------------------------

  def test_enqueue_sends_the_input_envelope_and_answers_the_queued_row
    accepted = chat([[202, {}, contract.fetch("valid_input_fixture")]]).inputs.create(
      kind: "direct_reply", text: "What is next?", model: "dev/text",
      reasoning_effort: "medium", expected_context_revision: 4,
      idempotency_key: "input-1"
    )

    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/inputs", request.fetch(:path)
    assert_equal "input-1", request.fetch(:headers).fetch("Idempotency-Key")
    fields = request.fetch(:body).fetch("input")
    assert_equal "direct_reply", fields.fetch("kind")
    assert_equal({ "model" => "dev/text", "reasoning_effort" => "medium" },
      fields.fetch("model"))
    assert_equal 4, fields.fetch("expected_context_revision")
    assert_equal 0, accepted.queue_position
    assert_equal "pending", accepted.state
    refute_predicate accepted, :blocked?
  end

  # PICTURES BESIDE THE WORDS: `attachments` is a list of
  # staged upload ids — or the `Upload` values `uploads.create` answered,
  # which are the same thing spelled once — sent as `input.attachments`
  # beside `text`; the row reads them back as `UploadRef`s in part order,
  # and a row with none reads nil, never an empty list.
  def test_attachments_ride_the_input_as_ids_or_uploads_and_read_back_in_part_order
    fixture = contract.fetch("valid_input_fixture")
    upload = CybrosAgent::Api::Upload.new(
      public_id: "01a0-upload", filename: "diagram.png", content_type: "image/png",
      byte_size: 184_213, created_at: "2026-09-12T00:00:00Z"
    )

    accepted = chat([[202, {}, fixture]]).inputs.create(
      text: "what is this?", attachments: [upload, "01a1-upload"], idempotency_key: "k"
    )

    assert_equal %w[01a0-upload 01a1-upload], request.fetch(:body).dig("input", "attachments"),
      "an Upload value spells its public id; a string is one already"
    picture = accepted.input.attachments.fetch(0)
    assert_instance_of CybrosAgent::Api::UploadRef, picture
    assert_equal fixture.dig("input", "attachments", 0, "public_id"), picture.public_id
    assert_equal "diagram.png", picture.filename
    assert_equal "image/png", picture.content_type
    assert_equal 184_213, picture.byte_size
    assert_equal({ public_id: picture.public_id, filename: "diagram.png", content_type: "image/png",
                   byte_size: 184_213 }, picture.to_h)

    chat([[200, {}, fixture]]).inputs.update("id", attachments: [])
    assert_equal [], request.fetch(:body).dig("input", "attachments"), "an empty list on an update UNBINDS"

    chat([[200, {}, fixture]]).inputs.update("id", text: "edited")
    refute request.fetch(:body).fetch("input").key?("attachments"),
      "no flag sends no field: the kernel keeps the row's pictures across a text edit"

    stripped = { "input" => fixture.fetch("input").except("attachments") }
    plain = chat([[202, {}, stripped]]).inputs.create(text: "x", idempotency_key: "k").input
    assert_nil plain.attachments, "a row with no pictures reads nil"
    refute plain.to_h.key?(:attachments)
  end

  def test_pdf_and_image_attachments_keep_their_order_and_descriptors_on_inputs_and_variants
    fixture = contract.fetch("valid_input_fixture")
    image = fixture.fetch("input").fetch("attachments").fetch(0)
    pdf = { "public_id" => "019aa123-0000-7000-8000-000000000002", "filename" => "report.pdf",
      "content_type" => "application/pdf", "byte_size" => 4096 }
    descriptors = [pdf, image]
    fixture = fixture.merge("input" => fixture.fetch("input").merge("attachments" => descriptors))
    upload = CybrosAgent::Api::Upload.new(**pdf.transform_keys(&:to_sym), created_at: "2026-09-12T00:00:00Z")

    accepted = chat([[202, {}, fixture]]).inputs.create(
      text: "Compare the report and image.", attachments: [upload, image.fetch("public_id")], idempotency_key: "pdf-input"
    )
    assert_equal descriptors.map { |item| item.fetch("public_id") }, request.fetch(:body).dig("input", "attachments")
    assert_equal descriptors.map { |item| item.transform_keys(&:to_sym) }, accepted.input.attachments.map(&:to_h)

    turns = contract.fetch("valid_turns_fixture")
    turns["turns"] = turns.fetch("turns").map do |row|
      row.key?("active_variant") ? row.merge("active_variant" => row.fetch("active_variant").merge("attachments" => descriptors)) : row
    end
    variant = chat([[200, {}, turns]]).turns.list.items.find(&:active_variant).active_variant
    assert_equal accepted.input.attachments, variant.attachments
    assert_equal descriptors.map { |item| item.transform_keys(&:to_sym) }, variant.to_h.fetch(:attachments).map(&:to_h)
  end

  # THE CLOCK ON THE ROW:
  # `deliver_in` (a delay: `90s`, `20m`, `2h`, `1d`) or `deliver_at` (a
  # Time, sent in UTC; or an ISO string sent AS GIVEN — the kernel is the
  # one parser) ride `create` and `update`; no keyword sends no field (the
  # kernel keeps the row's time); the row reads `deliver_at` back as the
  # ISO string the kernel holds, absent on an untimed row. No predicate:
  # a non-nil string is the fact, and the gem parses no time.
  def test_deliver_in_and_deliver_at_ride_create_and_update_and_the_row_reads_the_time_by_presence
    fixture = contract.fetch("scheduled_input_fixture")

    accepted = chat([[202, {}, fixture]]).inputs.create(text: "later", deliver_in: "20m", idempotency_key: "k")
    assert_equal "20m", request.fetch(:body).dig("input", "deliver_in"), "a delay as given"
    refute request.fetch(:body).fetch("input").key?("deliver_at")
    assert_equal fixture.dig("input", "deliver_at"), accepted.input.deliver_at
    assert_kind_of String, accepted.input.deliver_at, "the ISO string the kernel holds; the gem parses no time"

    chat([[202, {}, fixture]]).inputs.create(text: "later", deliver_at: Time.utc(2026, 9, 16, 9, 0, 0), idempotency_key: "k")
    assert_equal "2026-09-16T09:00:00Z", request.fetch(:body).dig("input", "deliver_at"), "a Time is sent in UTC"
    refute request.fetch(:body).fetch("input").key?("deliver_in")
    chat([[202, {}, fixture]]).inputs.create(text: "later", deliver_at: Time.new(2026, 9, 16, 17, 0, 0, "+08:00"),
      idempotency_key: "k")
    assert_equal "2026-09-16T09:00:00Z", request.fetch(:body).dig("input", "deliver_at"), "whatever zone it was made in"
    chat([[202, {}, fixture]]).inputs.create(text: "later", deliver_at: "2026-09-16T09:00:00+08:00", idempotency_key: "k")
    assert_equal "2026-09-16T09:00:00+08:00", request.fetch(:body).dig("input", "deliver_at"),
      "a string as given: the kernel judges it"

    row = chat([[200, {}, fixture]]).inputs.update("id", deliver_in: "0s")
    assert_equal "0s", request.fetch(:body).dig("input", "deliver_in"), "the clear is a typed value, never a null"
    assert_equal fixture.dig("input", "deliver_at"), row.deliver_at
    chat([[200, {}, fixture]]).inputs.update("id", deliver_at: Time.utc(2026, 9, 16, 9, 0, 0))
    assert_equal "2026-09-16T09:00:00Z", request.fetch(:body).dig("input", "deliver_at")
    chat([[200, {}, fixture]]).inputs.update("id", text: "edited")
    body = request.fetch(:body).fetch("input")
    refute body.key?("deliver_at"), "no keyword sends no field: the kernel keeps the row's time"
    refute body.key?("deliver_in")

    plain = chat([[202, {}, contract.fetch("valid_input_fixture")]]).inputs.create(text: "x", idempotency_key: "k").input
    assert_nil plain.deliver_at, "an untimed row reads nil"
    refute plain.to_h.key?(:deliver_at)
  end

  # The raw grammar places its own `upload` parts: `attachments` never ride
  # beside `entries`, and the gem refuses the pair before the wire.
  def test_attachments_and_entries_are_mutually_exclusive
    error = assert_raises(ArgumentError) do
      chat([]).inputs.create(entries: [{ "role" => "user", "parts" => [] }], attachments: ["01a0"], idempotency_key: "k")
    end
    assert_match(/attachments/, error.message)
    assert_raises(ArgumentError) { chat([]).inputs.update("id", entries: [], attachments: ["01a0"]) }
  end

  # A reply turn's variant shows the files its prompt carried — the
  # row's fact, whatever the answerer read — in the same `UploadRef` shape.
  def test_a_variant_reads_its_attachments_by_presence
    turns = contract.fetch("valid_turns_fixture")
    plain = chat([[200, {}, turns]]).turns.list.items.find(&:active_variant)
    assert_nil plain.active_variant.attachments, "the pack's variant carries none: nil, never an empty list"

    pictures = contract.dig("valid_input_fixture", "input", "attachments")
    carrying = { "turns" => turns.fetch("turns").map { |row|
      row.key?("active_variant") ? row.merge("active_variant" => row.fetch("active_variant").merge("attachments" => pictures)) : row
    }, "pagination" => turns.fetch("pagination") }
    turn = chat([[200, {}, carrying]]).turns.list.items.find(&:active_variant)
    picture = turn.active_variant.attachments.fetch(0)
    assert_instance_of CybrosAgent::Api::UploadRef, picture
    assert_equal "diagram.png", picture.filename
    assert_equal picture.to_h, turn.active_variant.to_h.fetch(:attachments).fetch(0).to_h
  end

  # THE TURN'S TOOL SUBSET: a list of
  # the declaring profile's flat names rides the input beside its model,
  # comes back on the row, and an empty list on an update is the clear.
  def test_tool_names_ride_the_input_and_read_back_by_presence
    fixture = contract.fetch("valid_input_fixture")
    accepted = chat([[202, {}, fixture]]).inputs.create(
      kind: "direct_reply", text: "x", model: "dev/text",
      tool_names: %w[read_file], idempotency_key: "k"
    )
    assert_equal %w[read_file], request.fetch(:body).fetch("input").fetch("tool_names")
    assert_equal fixture.dig("input", "tool_names"), accepted.input.tool_names
    refute_nil accepted.input.tool_names, "the contract's fixture carries the field"

    chat([[200, {}, fixture]]).inputs.update("id", tool_names: [])
    assert_equal [], request.fetch(:body).fetch("input").fetch("tool_names")

    chat([[202, {}, fixture]]).inputs.create(text: "x", idempotency_key: "k")
    refute request.fetch(:body).fetch("input").key?("tool_names"), "unset sends nothing"

    stripped = fixture.merge("input" => fixture.fetch("input").except("tool_names"))
    plain = chat([[202, {}, stripped]]).inputs.create(text: "x", idempotency_key: "k").input
    assert_nil plain.tool_names
    refute plain.to_h.key?(:tool_names), "absent stays absent"
  end

  # THE TURN'S TIGHTENING (the `tool_names` precedent): the
  # reply's `approval_mode` rides the input beside its model, comes back
  # on the row by presence, and is editable while queued; it only ever
  # ranks stricter than the declaring profile's word — the kernel refuses
  # a loosening 422 `validation_failed` naming it, and this SDK does not
  # pre-judge the rank.
  def test_approval_mode_rides_the_input_and_reads_back_by_presence
    fixture = contract.fetch("valid_input_fixture")
    accepted = chat([[202, {}, fixture]]).inputs.create(
      kind: "direct_reply", text: "x", model: "dev/text",
      approval_mode: "ask", idempotency_key: "k"
    )
    assert_equal "ask", request.fetch(:body).fetch("input").fetch("approval_mode")
    assert_equal fixture.dig("input", "approval_mode"), accepted.input.approval_mode
    refute_nil accepted.input.approval_mode, "the contract's fixture carries the field"

    chat([[200, {}, fixture]]).inputs.update("id", approval_mode: "rules")
    assert_equal "rules", request.fetch(:body).fetch("input").fetch("approval_mode")

    chat([[202, {}, fixture]]).inputs.create(text: "x", idempotency_key: "k")
    refute request.fetch(:body).fetch("input").key?("approval_mode"), "unset sends nothing"

    stripped = fixture.merge("input" => fixture.fetch("input").except("approval_mode"))
    plain = chat([[202, {}, stripped]]).inputs.create(text: "x", idempotency_key: "k").input
    assert_nil plain.approval_mode
    refute plain.to_h.key?(:approval_mode), "absent stays absent"

    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      chat([[422, {}, { "error" => { "code" => "validation_failed",
                                     "message" => "Approval mode only tightens the declaring profile's approval mode (bypass → ask → rules)" } }]])
        .inputs.create(kind: "direct_reply", text: "x", model: "dev/text",
          approval_mode: "bypass", idempotency_key: "k")
    end
    assert_equal "validation_failed", error.code
  end

  # RAW'S SYSTEM FIELD: `instructions` is the one field the `raw`
  # grammar has outside `entries` — the wire's own system slot, sealed as
  # sent — and it rides the body on both writers; the kernel refuses it on
  # an assembled input (422), and the SDK never pre-judges that.
  def test_instructions_ride_the_input_under_raw
    fixture = contract.fetch("valid_input_fixture")
    chat([[202, {}, fixture]]).inputs.create(
      kind: "direct_reply", model: "dev/text", context_mode: "raw",
      entries: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "raw" }] }],
      instructions: "Be brief.", idempotency_key: "k"
    )
    fields = request.fetch(:body).fetch("input")
    assert_equal "Be brief.", fields.fetch("instructions")
    assert_equal "raw", fields.fetch("context_mode")

    chat([[200, {}, fixture]]).inputs.update("id", instructions: "Be terse.")
    assert_equal "Be terse.", request.fetch(:body).fetch("input").fetch("instructions")

    chat([[202, {}, fixture]]).inputs.create(text: "x", idempotency_key: "k")
    refute request.fetch(:body).fetch("input").key?("instructions"), "unset sends nothing"

    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      chat([[422, {}, { "error" => { "code" => "validation_failed", "message" => "Instructions is invalid" } }]])
        .inputs.create(kind: "direct_reply", text: "x", model: "dev/text",
          instructions: "Be brief.", idempotency_key: "k")
    end
    assert_equal "validation_failed", error.code, "the kernel's word on an assembled input"
  end

  # THE ROUND TRIP: what the SDK wrote as `instructions:` reads back
  # on the row the door answers and on the list — the pack's raw row
  # carries it, an assembled row reads none.
  def test_instructions_read_back_on_the_input_row
    raw = contract.fetch("valid_raw_input_fixture")
    created = chat([[202, {}, raw]]).inputs.create(
      kind: "direct_reply", model: "dev/text", context_mode: "raw",
      entries: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "raw" }] }],
      instructions: "Be brief.", idempotency_key: "k"
    )

    assert_equal "Be brief.", request.fetch(:body).fetch("input").fetch("instructions")
    assert_equal "Be brief.", created.input.instructions, "the row reads back what the door was sent"
    assert_equal "raw", created.input.context_mode
    assert_nil created.input.text, "a raw row's body is its entries"
    assert_equal "Be brief.", created.input.to_h.fetch(:instructions)

    listed = chat([[200, {}, contract.fetch("valid_inputs_fixture")]]).inputs.list
    assert_nil listed.first.instructions, "an assembled row carries none"
    refute listed.first.to_h.key?(:instructions), "and compacts it away"
  end

  # THE INLINE SLOT OVERRIDE needs no SDK grammar: `inline:`
  # passes through as given, so an entry naming a slot rides verbatim.
  def test_an_inline_slot_entry_passes_through_untouched
    fixture = contract.fetch("valid_input_fixture")
    override = [{ "slot" => "character", "text" => "For this turn: be terse." }]
    accepted = chat([[202, {}, fixture]]).inputs.create(
      kind: "direct_reply", text: "x", model: "dev/text", inline: override, idempotency_key: "k"
    )

    assert_equal override, request.fetch(:body).fetch("input").fetch("inline")
    assert_equal override, accepted.input.context_options.fetch("inline"),
      "the pack's input fixture carries the slot entry the kernel stored"
  end

  # KERNEL MAIL: a background task's answer
  # that outlived its turn reads `origin: task_result` with the run's own
  # conversation as the sender — on the input and on the turn it became;
  # a caller's word reads its author's kind (`person`) and no sender.
  def test_kernel_result_delivery_names_its_origin_and_sender_on_the_input_and_the_turn
    body = contract.fetch("valid_input_fixture")
    stamped = body.merge("input" => body.fetch("input").merge(
      "origin" => "task_result", "sender_conversation_public_id" => CONVERSATION_ID
    ))
    mail = chat([[202, {}, stamped]]).inputs.create(text: "x", idempotency_key: "k").input
    assert_equal "task_result", mail.origin
    assert_equal CONVERSATION_ID, mail.sender_conversation_public_id
    assert_predicate mail, :task_result?

    plain = chat([[202, {}, body]]).inputs.create(text: "x", idempotency_key: "k").input
    assert_equal "person", plain.origin, "the source kind is on every input"
    refute_predicate plain, :task_result?
    assert_nil plain.sender_conversation_public_id
    refute plain.to_h.key?(:sender_conversation_public_id), "absent stays absent"

    turns = contract.fetch("valid_turns_fixture")
    mailed_turn = turns.fetch("turns").first.merge("kind" => "message", "role" => "user",
      "origin" => "task_result", "sender_conversation_public_id" => CONVERSATION_ID).except("active_variant")
    turn = chat([[200, {}, turns.merge("turns" => [mailed_turn])]]).turns.list.first
    assert_equal "task_result", turn.origin
    assert_predicate turn, :task_result?
    refute_predicate chat([[200, {}, turns]]).turns.list.first, :task_result?
  end

  def test_source_execution_attribution_survives_a_durable_turn_read
    stamped = contract.fetch("valid_stamped_turn_fixture")
    turns = contract.fetch("valid_turns_fixture").merge("turns" => [stamped])
    turn = chat([[200, {}, turns]]).turns.list.first
    assert_equal stamped.fetch("sender_run_public_id"), turn.sender_run_public_id
    assert_equal stamped.fetch("sender_task_key"), turn.sender_task_key
    assert_equal stamped.fetch("sender_conversation_public_id"), turn.sender_conversation_public_id
  end

  # THE ADDRESSEE (group chat): `to:` names who answers this
  # turn — `@handle` or a public id — and rides the wire as the create
  # door's word, `answering_user_public_id`; omitted sends nothing (the
  # conversation's answerer). Every input and turn reads its answerer
  # back, and a `speaker` block — who spoke it: a row's author, a message
  # turn's speaker, a reply turn's ANSWERER — so a two-instant `turns.list`
  # read can say which agent's turn is running and which agent answered.
  def test_to_rides_the_input_and_the_answerer_and_speaker_read_back_on_inputs_and_turns
    fixture = contract.fetch("valid_input_fixture")
    accepted = chat([[202, {}, fixture]]).inputs.create(
      kind: "direct_reply", text: "B, your view?", model: "dev/text", to: "@lark", idempotency_key: "k"
    )
    assert_equal "@lark", request.fetch(:body).fetch("input").fetch("answering_user_public_id")
    refute request.fetch(:body).fetch("input").key?("to"), "the SDK's keyword is not the wire's word"
    assert_equal fixture.dig("input", "answering_user_public_id"), accepted.input.answering_user_public_id
    refute_nil accepted.input.answering_user_public_id, "the contract's fixture carries the addressee"
    speaker = accepted.input.speaker
    assert_equal fixture.dig("input", "speaker").values_at("user_public_id", "handle", "kind", "display_name"),
      [speaker.user_public_id, speaker.handle, speaker.kind, speaker.display_name]

    chat([[202, {}, fixture]]).inputs.create(text: "x", idempotency_key: "k")
    refute request.fetch(:body).fetch("input").key?("answering_user_public_id"), "unset sends nothing"

    turns = contract.fetch("valid_turns_fixture")
    settled = turns.fetch("turns").first
    turn = chat([[200, {}, turns]]).turns.list.first
    assert_equal settled.fetch("answering_user_public_id"), turn.answering_user_public_id
    assert_equal settled.fetch("speaker").fetch("user_public_id"), turn.speaker.user_public_id
    assert_equal turn.answering_user_public_id, turn.speaker.user_public_id,
      "a reply turn's speaker IS its answerer: the settled group-turn fixture is another agent's reply"
    assert_equal "agent", turn.speaker.kind

    summary = settled.merge("kind" => "compaction_summary", "role" => "user").except("speaker", "active_variant")
    kernel = chat([[200, {}, turns.merge("turns" => [summary])]]).turns.list.first
    assert_nil kernel.speaker, "the kernel's summary names no principal"
    refute kernel.to_h.key?(:speaker), "absent stays absent"
  end

  def test_text_and_entries_are_mutually_exclusive_on_both_writers
    assert_raises(ArgumentError) do
      chat([]).inputs.create(text: "a", entries: [], idempotency_key: "k")
    end
    assert_raises(ArgumentError) { chat([]).inputs.update("id", text: "a", entries: []) }
  end

  def test_a_blocked_head_carries_the_reason_and_updating_it_is_the_unblock_path
    blocked = contract.fetch("valid_inputs_fixture")
    blocked = blocked.merge("inputs" => [blocked.fetch("inputs").first.merge(
      "state" => "blocked", "blocked_reason" => "estimated_input_exceeds_model_limit"
    )])
    list = chat([[200, {}, blocked]]).inputs.list

    assert_predicate list.first, :blocked?
    assert_equal "estimated_input_exceeds_model_limit", list.first.blocked_reason
    assert_equal 32, list.input_queue.limit

    chat([[200, {}, contract.fetch("valid_input_fixture")]])
      .inputs.update(list.first.public_id, text: "shorter", expected_lock_version: 0)
    assert_equal :patch, request.fetch(:method)
    assert_equal 0, request.fetch(:body).fetch("input").fetch("expected_lock_version")
  end

  def test_reorder_sends_the_exact_set
    ordered = chat([[200, {}, contract.fetch("valid_inputs_fixture")]])
      .inputs.reorder(%w[a b c])

    assert_equal "#{PATH}/inputs/reorder", request.fetch(:path)
    assert_equal({ "inputs" => %w[a b c] }, request.fetch(:body))
    assert_equal 1, ordered.length
  end
end
