require "support/dev_commands"

class DevCommandsTest
  # THE BYTES A ROUND OR A TURN WAS SENT: the options, then the
  # entries, each as pretty JSON — a debug verb's whole value is the bytes,
  # and a line-per-entry rendering would hide them. The second argument's
  # SHAPE picks the reading: a task key (`r1`, an authored word) or a
  # UUID-shaped turn id.
  def test_request_prints_the_options_then_the_entries_as_json
    entries = [{ "role" => "system", "parts" => [{ "type" => "text", "text" => "guide" }] },
               { "role" => "user", "parts" => [{ "type" => "text", "text" => "fix it" }] }]
    options = { "temperature" => 0.2, "tools" => [] }
    turn = "0199a7f0-1234-7000-8000-000000000001"
    announce(endpoint: routed_endpoint(
      "GET /runs/request?public_id=al-9&task_key=r1" => [[200, { "request" => { "entries" => entries, "request_options" => options } }]],
      "GET /runs/request?public_id=c-1&turn=#{turn}" => [[200, { "request" => { "entries" => entries, "request_options" => options } }]]
    ))
    expected = "request_options:\n#{JSON.pretty_generate(options)}\n\nentries:\n#{JSON.pretty_generate(entries)}\n"

    printed = ops(:request, "al-9", "r1")
    assert_equal({ "entries" => entries, "request_options" => options }, printed)
    assert_equal expected, @out.string

    @out.truncate(0)
    @out.rewind
    ops(:request, "c-1", turn)
    assert_equal expected, @out.string
  end

  def test_request_needs_its_two_words_and_carries_the_daemon_s_refusal
    announce(endpoint: routed_endpoint(
      "GET /runs/request?public_id=al-9&task_key=r1t0" => [[404, { "error" => { "code" => "request_not_sealed", "message" => "no sealed request" } }]]
    ))

    error = assert_raises(Rho::Error) { ops(:request, "al-9") }
    assert_includes error.message, "TASK_KEY"
    error = assert_raises(Rho::Error) { ops(:request, "al-9", "r1t0") }
    assert_includes error.message, "no sealed request"
  end

  # THE PREVIEW FROM A TERMINAL: `rho prompt preview`
  # posts the estimate rendered through the daemon — the model, the words,
  # the addressee, the turn's variables and a trial template from a file —
  # and prints the evidence a person reads first (the mechanism, the count,
  # history, the storage line, one row per block) and then the entries as
  # pretty JSON, exactly as `request` prints a sealed one: a debug verb's
  # whole value is the bytes. `--json` prints the document whole.
  PREVIEW = {
    "mechanism" => "assembly", "input_tokens" => 812, "tokenizer_exact" => true,
    "catalog_input_token_limit" => 128_000, "advisory_input_token_limit" => 100_000, "message_count" => 2,
    "history" => { "selected" => 4, "skipped" => 12, "skipped_reason" => "budget_exceeded", "compacted" => 9 },
    "entries" => [
      { "role" => "system", "parts" => [{ "type" => "text", "text" => "You are the room's narrator." }] },
      { "role" => "user", "parts" => [{ "type" => "text", "text" => "first\n\nand this question" }] },
    ],
    "storage" => { "bytes" => 158, "bound" => 1_048_576, "within_bound" => true },
    "blocks" => [
      { "block" => "slot:system_prompt", "index" => 0, "type" => "slot", "role" => "system", "state" => "selected",
        "tokens" => 6, "allocated_tokens" => 6 },
      { "block" => "memory", "index" => 1, "type" => "memory", "role" => nil, "state" => "empty",
        "tokens" => 0, "allocated_tokens" => 0 },
      { "block" => "history", "index" => 2, "type" => "history", "role" => "user", "state" => "selected",
        "tokens" => 3, "allocated_tokens" => 99_991 },
      { "block" => "input", "index" => 3, "type" => "input", "role" => "user", "state" => "selected",
        "tokens" => 4, "allocated_tokens" => 4 },
    ],
    "memory" => { "included" => 0, "omitted" => 0 },
    "slots" => { "system_prompt" => 4 },
  }.freeze

  def test_prompt_preview_prints_the_evidence_then_the_entries_and_posts_the_four_fields
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /conversations/prompt_preview" => [[200, { "preview" => PREVIEW }]]))
    template = { "blocks" => [{ "type" => "slot", "slot" => "system_prompt" }, { "type" => "memory" },
                              { "type" => "history" }, { "type" => "input" }] }
    Dir.mktmpdir do |dir|
      path = File.join(dir, "order.json")
      File.write(path, JSON.generate(template))

      printed = ops(:prompt, "preview", "c-1", model: "dev/mock-text", prompt: "and this question", to: "@narrator",
        var: ["scene=a rainy night", "mood=calm=ish"], template: path)

      assert_equal PREVIEW, printed
    end

    body = JSON.parse(seen.grep(%r{\APOST /conversations/prompt_preview}).fetch(0).partition("\r\n\r\n").last)
    assert_equal({ "public_id" => "c-1", "model" => "dev/mock-text", "prompt" => "and this question",
                   "to" => "@narrator", "variables" => { "scene" => "a rainy night", "mood" => "calm=ish" },
                   "template" => template }, body,
      "the addressee, the values (split at the first `=`) and the file's template ride the one POST")

    lines = @out.string.lines.map(&:chomp)
    assert_equal "mechanism: assembly", lines[0]
    assert_equal "tokens:    812 (exact)  limit 128000  advisory 100000", lines[1]
    assert_equal "history:   selected 4  skipped 12 (budget_exceeded)  compacted 9", lines[2]
    assert_equal "storage:   158 of 1048576 bytes (within bound)", lines[3]
    assert_equal "blocks:", lines[4]
    assert_match(/^\s+#\s+block\s+type\s+role\s+state\s+tokens\s+allocated$/, lines[5])
    assert_match(/^\s+0\s+slot:system_prompt\s+slot\s+system\s+selected\s+6\s+6$/, lines[6])
    assert_match(/^\s+1\s+memory\s+memory\s+-\s+empty\s+0\s+0$/, lines[7], "a role-less block prints a dash")
    assert_match(/^\s+3\s+input\s+input\s+user\s+selected\s+4\s+4$/, lines[9])
    assert_equal "memory:    0 included, 0 omitted", lines[10]
    assert_equal "slots:     system_prompt v4", lines[11]
    assert_equal "", lines[12]
    assert_equal "entries:", lines[13]
    assert_equal JSON.pretty_generate(PREVIEW.fetch("entries")), lines[14..].join("\n")
  end

  # Over the seal's bound the storage line carries the refusal word; a
  # block the window could not fund prints its state as the kernel said it
  # — evidence, never a byte change; a windowless model prints no grant.
  def test_prompt_preview_prints_the_overflow_and_the_unfunded_floor
    over = PREVIEW.merge(
      "storage" => { "bytes" => 2_000_000, "bound" => 1_048_576, "within_bound" => false, "refusal" => "content_too_large" },
      "blocks" => [PREVIEW.fetch("blocks").first.merge("state" => "floor_unmet", "allocated_tokens" => nil)]
    )
    announce(endpoint: routed_endpoint("POST /conversations/prompt_preview" => [[200, { "preview" => over }]]))

    ops(:prompt, "preview", "c-1", model: "dev/mock-text")

    assert_match(/^storage:   2000000 of 1048576 bytes \(over: content_too_large\)$/, @out.string, @out.string)
    assert_match(/^\s+0\s+slot:system_prompt\s+slot\s+system\s+floor_unmet\s+6\s+-$/, @out.string, @out.string)
  end

  def test_prompt_preview_json_prints_the_document_whole
    announce(endpoint: routed_endpoint("POST /conversations/prompt_preview" => [[200, { "preview" => PREVIEW }]]))

    ops(:prompt, "preview", "c-1", model: "dev/mock-text", json: true)

    assert_equal PREVIEW, JSON.parse(@out.string)
  end

  def test_prompt_needs_its_verb_and_the_id_and_carries_the_daemon_s_refusal
    announce(endpoint: routed_endpoint(
      "POST /conversations/prompt_preview" => [[422, { "error" => { "code" => "prompt_template_invalid",
        "message" => "Prompt template is outside the template grammar (after_input) at /blocks/3" } }]]
    ))

    error = assert_raises(Rho::Error) { ops(:prompt) }
    assert_includes error.message, "preview"
    error = assert_raises(Rho::Error) { ops(:prompt, "write", "system_prompt") }
    assert_includes error.message, "preview", "`write` is not a verb here: rho rewrites its own slot at every boot"
    error = assert_raises(Rho::Error) { ops(:prompt, "preview") }
    assert_includes error.message, "CONVERSATION_ID"
    error = assert_raises(Rho::Error) { ops(:prompt, "preview", "c-1", var: ["scene"]) }
    assert_includes error.message, "name=value"
    error = assert_raises(Rho::Error) { ops(:prompt, "preview", "c-1", template: "/nowhere/order.json") }
    assert_includes error.message, "/nowhere/order.json"
    error = assert_raises(Rho::Error) { ops(:prompt, "preview", "c-1", model: "dev/mock-text") }
    assert_includes error.message, "/blocks/3", "the kernel's refusal names its path"
  end

  # `rho prompt show`: the acting user's own slots — rho's `system_prompt`
  # — listed, or one read whole. No `write`/`delete`: rho rewrites its
  # slot from the guideline at every declare edge, so a person's write
  # would be reverted at the next boot.
  def test_prompt_show_lists_the_slots_and_reads_one
    listing = { "prompt_documents" => [
      { "slot" => "system_prompt", "role" => "system", "bytesize" => 41, "version" => 3, "written_at" => "2026-09-08T00:00:00Z" },
    ] }
    document = { "prompt_document" => listing.fetch("prompt_documents").first.merge("content" => "Prefer small diffs.") }
    announce(endpoint: routed_endpoint(
      "GET /prompt/documents?slot=system_prompt" => [[200, document]],
      "GET /prompt/documents" => [[200, listing]]
    ))

    rows = ops(:prompt, "show")
    assert_equal listing.fetch("prompt_documents"), rows
    assert_match(/^system_prompt\s+system\s+v3\s+41 bytes\s+2026-09-08T00:00:00Z$/, @out.string, @out.string)

    @out.truncate(0)
    @out.rewind
    read = ops(:prompt, "show", "system_prompt")
    assert_equal document.fetch("prompt_document"), read
    assert_equal "Prefer small diffs.\n", @out.string, "the content alone, as written: macros unrendered"
  end

  def test_prompt_show_says_when_no_slot_is_written
    announce(endpoint: routed_endpoint(
      "GET /prompt/documents?slot=persona" => [[404, { "error" => { "code" => "prompt_slot_unavailable",
        "message" => "This profile cannot hold persona" } }]],
      "GET /prompt/documents" => [[200, { "prompt_documents" => [] }]]
    ))

    ops(:prompt, "show")
    assert_equal "(no prompt documents on this profile)\n", @out.string
    error = assert_raises(Rho::Error) { ops(:prompt, "show", "persona") }
    assert_includes error.message, "cannot hold persona"
  end
end
