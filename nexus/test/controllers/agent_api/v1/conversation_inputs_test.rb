require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationInputsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "public input creation cannot inject kernel callback provenance" do
    conversation = create_conversation!
    %w[callback_result callback_sources input_public_id].each do |field|
      forged = SecureRandom.uuid_v7
      post conversation_inputs_path(conversation), headers: auth("inject-#{field}"), as: :json,
        params: { input: { text: "ordinary input", field => forged } }
      assert_response :accepted
      input = conversation.conversation_inputs.find_by!(public_id: response.parsed_body.dig("input", "public_id"))
      assert_nil input.callback_result
      outcome = Conversations::Inputs::ApplyNext.call(conversation_id: conversation.id)
      assert_predicate outcome, :accepted?
      assert_equal input.public_id, outcome.value.input_public_id
      assert_not_equal forged, outcome.value.input_public_id
      assert_empty outcome.value.callback_sources
    end
    assert_empty conversation.conversation_inputs
  end

  # The kernel's receipt on the wire: listed in READ order — ahead of an earlier caller row,
  # `queue_position` still its arrival number — and immutable to the person by name.
  test "a receipt lists first and refuses the edit surface 409 kernel_input_immutable" do
    conversation = create_conversation!
    post conversation_inputs_path(conversation), headers: auth("i-1"), as: :json,
      params: { input: { text: "first, by arrival" } }
    assert_response :accepted
    first = response.parsed_body.fetch("input")
    receipt = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
      host: conversation, acting_user: @human,
      entries: [{ "text" => "<task_result task=\"r2t0\" status=\"completed\">done</task_result>" }],
      origin: ConversationInput::TASK_RESULT_ORIGIN, sender_conversation_public_id: conversation.public_id
    )).value
    post conversation_inputs_path(conversation), headers: auth("i-2"), as: :json,
      params: { input: { text: "second, by arrival" } }
    second = response.parsed_body.fetch("input")

    get conversation_inputs_path(conversation), headers: auth
    assert_response :success
    listed = response.parsed_body.fetch("inputs")
    assert_equal [receipt.public_id, first["public_id"], second["public_id"]], listed.map { |row| row["public_id"] }
    assert_equal [1, 0, 2], listed.map { |row| row["queue_position"] }
    assert_equal "task_result", listed.first["origin"]
    assert_equal 2, response.parsed_body.dig("input_queue", "held"), "the receipt is not the person's"

    patch "#{conversation_inputs_path(conversation)}/#{receipt.public_id}", headers: auth, as: :json,
      params: { input: { text: "rewritten" } }
    assert_response :conflict
    assert_equal "kernel_input_immutable", response.parsed_body.dig("error", "code")

    delete "#{conversation_inputs_path(conversation)}/#{receipt.public_id}", headers: auth
    assert_response :conflict
    assert_equal "kernel_input_immutable", response.parsed_body.dig("error", "code")

    post "#{conversation_inputs_path(conversation)}/reorder", headers: auth, as: :json,
      params: { inputs: [receipt.public_id, second["public_id"], first["public_id"]] }
    assert_response :conflict
    assert_equal "kernel_input_immutable", response.parsed_body.dig("error", "code")

    post "#{conversation_inputs_path(conversation)}/reorder", headers: auth, as: :json,
      params: { inputs: [second["public_id"], first["public_id"]] }
    assert_response :success
    assert_equal [second["public_id"], first["public_id"]],
      response.parsed_body.fetch("inputs").map { |row| row["public_id"] }
    assert_equal 1, receipt.reload.queue_position
  end

  # The receipt is HOSTED: one key replays on its own host and is a scoped miss on another, with the
  # digest still fencing the envelope.
  test "an input's receipt replays on its host and never across hosts" do
    first = create_conversation!(title: "first")
    second = create_conversation!(title: "second")
    body = { input: { text: "same words" } }

    post conversation_inputs_path(first), headers: auth("shared-key"), as: :json, params: body
    assert_response :accepted
    assert_equal "false", response.headers["Idempotency-Replayed"]
    accepted = response.parsed_body.dig("input", "public_id")

    post conversation_inputs_path(first), headers: auth("shared-key"), as: :json, params: body
    assert_response :accepted
    assert_equal "true", response.headers["Idempotency-Replayed"]
    assert_equal accepted, response.parsed_body.dig("input", "public_id"), "the stored 202"

    post conversation_inputs_path(second), headers: auth("shared-key"), as: :json, params: body
    assert_response :accepted
    assert_equal "false", response.headers["Idempotency-Replayed"]
    assert_not_equal accepted, response.parsed_body.dig("input", "public_id"),
      "another host is a scoped miss, not a replay"

    post conversation_inputs_path(first), headers: auth("shared-key"), as: :json,
      params: { input: { text: "different words" } }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")

    receipts = ConversationCommandReceipt.where(operation: "input_create")
    assert_equal [first, second].map(&:id).sort, receipts.pluck(:host_id).sort
    assert_equal ["Conversation"], receipts.distinct.pluck(:host_type)
  end

  # The turn's approval tightening rides the input beside `tool_names`: rendered on the row,
  # editable while queued, refused by sentence when it would loosen the declaring profile's word.
  test "approval_mode rides the input envelope as a tightening of the declaring profile's mode" do
    agent = users(:agent)
    outcome = Users::DeclareConfiguration.call(user: agent,
      tool_definitions: [
        { "type" => "function", "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } },
      ],
      approval_mode: "bypass", approval_rules: nil, prompt_mechanism: nil, prompt_template: nil,
      compaction_policy: nil
    )
    assert_equal :declared, outcome.outcome
    conversation = Conversation.create!(workspace: @workspace, creating_user: agent)

    post conversation_inputs_path(conversation), headers: auth("a-1"), as: :json,
      params: { input: { kind: "direct_reply", text: "carefully", model: { model: "dev/mock-text" },
                         approval_mode: "ask" } }
    assert_response :accepted
    assert_equal "ask", response.parsed_body.dig("input", "approval_mode")
    input_public_id = response.parsed_body.dig("input", "public_id")

    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}",
      headers: auth, as: :json, params: { input: { approval_mode: "rules" } }
    assert_response :success
    assert_equal "rules", response.parsed_body.dig("input", "approval_mode"), "editable while queued"

    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}",
      headers: auth, as: :json, params: { input: { text: "still" } }
    assert_response :success
    assert_equal "rules", response.parsed_body.dig("input", "approval_mode"), "nil is untouched"

    post conversation_inputs_path(conversation), headers: auth("a-2"), as: :json,
      params: { input: { kind: "direct_reply", text: "x", model: { model: "dev/mock-text" }, approval_mode: "telepathy" } }
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")

    post conversation_inputs_path(conversation), headers: auth("a-3"), as: :json,
      params: { input: { kind: "message", text: "x", approval_mode: "ask" } }
    assert_response :unprocessable_entity, "a message compiles no request"

    post conversation_inputs_path(conversation), headers: auth("a-4"), as: :json,
      params: { input: { kind: "direct_reply", text: "x", model: { model: "dev/mock-text" } } }
    assert_response :accepted
    assert_nil response.parsed_body.dig("input", "approval_mode"), "absent means the profile's word"
  end

  # The turn's tool subset rides the input: a list of the declaring
  # profile's flat names, rendered back on the
  # row; a name the profile does not declare is the door's typed refusal.
  test "tool_names rides the input envelope as a subset of the declaring profile's declaration" do
    agent = users(:agent)
    outcome = Users::DeclareConfiguration.call(user: agent,
      tool_definitions: [
        { "type" => "function", "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } },
        { "type" => "function", "function" => { "name" => "write_file", "parameters" => { "type" => "object" } } },
      ],
      approval_mode: "bypass", approval_rules: nil, prompt_mechanism: nil, prompt_template: nil,
      compaction_policy: nil
    )
    assert_equal :declared, outcome.outcome
    conversation = Conversation.create!(workspace: @workspace, creating_user: agent)

    post conversation_inputs_path(conversation), headers: auth("t-1"), as: :json,
      params: { input: { kind: "direct_reply", text: "narrow ask",
                         model: { model: "dev/mock-text" }, tool_names: %w[read_file] } }
    assert_response :accepted
    assert_equal %w[read_file], response.parsed_body.dig("input", "tool_names")
    input_public_id = response.parsed_body.dig("input", "public_id")

    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}",
      headers: auth, as: :json, params: { input: { tool_names: %w[write_file] } }
    assert_response :success
    assert_equal %w[write_file], response.parsed_body.dig("input", "tool_names"),
      "editable while queued, like the model trio"

    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}",
      headers: auth, as: :json, params: { input: { tool_names: [] } }
    assert_response :success
    assert_equal [], response.parsed_body.dig("input", "tool_names"),
      "an empty list is NO TOOLS, on the edit as on the create — never a clear gesture"

    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}",
      headers: auth, as: :json, params: { input: { tool_names: %w[read_file write_file] } }
    assert_response :success
    assert_equal %w[read_file write_file], response.parsed_body.dig("input", "tool_names"),
      "back to the whole declaration is the whole declaration by name (the approval_mode precedent)"

    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}",
      headers: auth, as: :json, params: { input: { tool_names: %w[compose] } }
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(/compose/, response.parsed_body.dig("error", "message"), "the offending name is named")

    post conversation_inputs_path(conversation), headers: auth("t-2"), as: :json,
      params: { input: { kind: "direct_reply", text: "x",
                         model: { model: "dev/mock-text" }, tool_names: %w[read_file compose] } }
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(/compose/, response.parsed_body.dig("error", "message"))

    post conversation_inputs_path(conversation), headers: auth("t-3"), as: :json,
      params: { input: { kind: "message", text: "x", tool_names: %w[read_file] } }
    assert_response :unprocessable_entity, "a message compiles no request"
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")

    post conversation_inputs_path(conversation), headers: auth("t-4"), as: :json,
      params: { input: { kind: "direct_reply", text: "x",
                         model: { model: "dev/mock-text" }, tool_names: "read_file" } }
    assert_response :bad_request, "a scalar is no list"
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
  end

  test "the history intent rides the input envelope, typed at the boundary" do
    conversation = create_conversation!

    post conversation_inputs_path(conversation), headers: auth("h-1"), as: :json,
      params: { input: { kind: "direct_reply", text: "bounded ask",
                         model: { model: "dev/mock-text" },
                         history: { max_entries: 2, token_budget_share: 0.25 } } }

    assert_response :accepted
    assert_equal({ "history" => { "max_entries" => 2, "token_budget_share" => 0.25 } },
      response.parsed_body.dig("input", "context_options"))

    input_public_id = response.parsed_body.dig("input", "public_id")
    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}",
      headers: auth, as: :json, params: { input: { history: { max_entries: 1 } } }
    assert_response :success
    assert_equal({ "history" => { "max_entries" => 1 } },
      response.parsed_body.dig("input", "context_options"),
      "the edit replaces the whole intent — the estimate surface's exact vocabulary")

    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}",
      headers: auth, as: :json, params: { input: { history: nil } }
    assert_response :success
    assert_nil response.parsed_body.dig("input", "context_options"),
      "history: null is the clear gesture — back to pristine, not silently ignored"

    post conversation_inputs_path(conversation), headers: auth("h-2"), as: :json,
      params: { input: { text: "x", history: { token_budget_share: 2 } } }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")

    post conversation_inputs_path(conversation), headers: auth("h-3"), as: :json,
      params: { input: { kind: "direct_reply", text: "quiet ask",
                         model: { model: "dev/mock-text" },
                         reasoning_replay: { mode: "none" } } }
    assert_response :accepted
    assert_equal({ "reasoning_replay" => { "mode" => "none" } },
      response.parsed_body.dig("input", "context_options"))

    post conversation_inputs_path(conversation), headers: auth("h-4"), as: :json,
      params: { input: { kind: "direct_reply", text: "x",
                         model: { model: "dev/mock-text" },
                         reasoning_replay: { mode: "sometimes" } } }
    assert_response :bad_request

    post conversation_inputs_path(conversation), headers: auth("h-5"), as: :json,
      params: { input: { kind: "direct_reply", text: "styled ask",
                         model: { model: "dev/mock-text" },
                         inline: [{ role: "developer", text: "you are terse" }] } }
    assert_response :accepted
    assert_equal(
      { "inline" => [{ "role" => "developer", "text" => "you are terse" }] },
      response.parsed_body.dig("input", "context_options")
    )

    # A positioned entry rides the turn's preface behind history: never `system`.
    post conversation_inputs_path(conversation), headers: auth("h-5-system"), as: :json,
      params: { input: { kind: "direct_reply", text: "styled ask",
                         model: { model: "dev/mock-text" },
                         inline: [{ role: "system", text: "you are terse", position: "tail" }] } }
    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_match(/system-role inline entry by position/, response.parsed_body.dig("error", "message"))

    post conversation_inputs_path(conversation), headers: auth("h-6"), as: :json,
      params: { input: { kind: "direct_reply", text: "x",
                         model: { model: "dev/mock-text" },
                         inline: [{ role: "tool", text: "x" }] } }
    assert_response :bad_request
  end

  # THE VARIABLES INTENT AT THE DOOR: `variables` rides the input envelope beside `history` and
  # `inline`, body-read as an object — the permit filter would strip it without a word, the one
  # silent drop the intent rule forbids — and stored on `context_options` for the drain; a
  # non-object is the boundary's 400, and against a `default` addressee the model's 422 (nothing
  # would read it).
  test "the variables intent rides the input envelope as an object and lands on context_options" do
    agent = users(:agent)
    outcome = Users::DeclareConfiguration.call(user: agent,
      tool_definitions: [], approval_mode: nil, approval_rules: nil, prompt_mechanism: "assembly",
      prompt_template: { "blocks" => [{ "type" => "history" }, { "type" => "input" }],
                         "variables" => { "scene" => "an ordinary day" } },
      compaction_policy: nil
    )
    assert_equal :declared, outcome.outcome
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent)

    post conversation_inputs_path(conversation), headers: auth("v-1"), as: :json,
      params: { input: { kind: "direct_reply", text: "set the scene", model: { model: "dev/mock-text" },
                         variables: { scene: "a rainy night" } } }
    assert_response :accepted
    assert_equal({ "variables" => { "scene" => "a rainy night" } },
      response.parsed_body.dig("input", "context_options"))

    post conversation_inputs_path(conversation), headers: auth("v-2"), as: :json,
      params: { input: { kind: "direct_reply", text: "x", model: { model: "dev/mock-text" }, variables: "scene" } }
    assert_response :bad_request, "variables is an object"
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")

    post conversation_inputs_path(conversation), headers: auth("v-3"), as: :json,
      params: { input: { kind: "direct_reply", text: "x", model: { model: "dev/mock-text" },
                         variables: { mood: "tense" } } }
    assert_response :unprocessable_entity, "an undeclared name is the model's refusal, by name"
    assert_match(/mood/, response.parsed_body.dig("error", "message"))

    plain = create_conversation!
    post conversation_inputs_path(plain), headers: auth("v-4"), as: :json,
      params: { input: { kind: "direct_reply", text: "x", model: { model: "dev/mock-text" },
                         variables: { scene: "x" } } }
    assert_response :unprocessable_entity, "a default addressee reads no variables: the intent would do nothing"
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
  end

  # THE INLINE SLOT OVERRIDE and `raw`'s `instructions` at the door: a slot entry is stored as sent,
  # a slot beside a position is a 400 at the boundary, and `instructions` rides only under
  # `context_mode: raw` — the model's 422 elsewhere. The door's refusal is the slot door's own: 422
  # `prompt_document_macro_unknown`, the word in the message.
  test "an inline slot override with an unknown macro is refused as the slot door refuses it" do
    conversation = create_conversation!

    post conversation_inputs_path(conversation), headers: auth("macro-1"), as: :json,
      params: { input: { kind: "direct_reply", text: "hi", model: { model: "dev/mock-text" },
                         inline: [{ slot: "character", text: "The room is {{mood}}." }] } }

    assert_response :unprocessable_entity
    assert_equal "prompt_document_macro_unknown", response.parsed_body.dig("error", "code")
    assert_match(/\{\{mood\}\}/, response.parsed_body.dig("error", "message"))
  end

  test "an inline slot entry is admitted, slot with position refused, instructions raw-only" do
    conversation = create_conversation!

    post conversation_inputs_path(conversation), headers: auth("s-1"), as: :json,
      params: { input: { kind: "direct_reply", text: "styled ask",
                         model: { model: "dev/mock-text" },
                         inline: [{ slot: "character", text: "You are the room." }] } }
    assert_response :accepted
    assert_equal({ "inline" => [{ "slot" => "character", "text" => "You are the room." }] },
      response.parsed_body.dig("input", "context_options"))

    post conversation_inputs_path(conversation), headers: auth("s-2"), as: :json,
      params: { input: { kind: "direct_reply", text: "x",
                         model: { model: "dev/mock-text" },
                         inline: [{ slot: "character", position: "lead", text: "x" }] } }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), "inline"

    post conversation_inputs_path(conversation), headers: auth("s-3"), as: :json,
      params: { input: { kind: "direct_reply", context_mode: "raw", instructions: "Be brief.",
                         model: { model: "dev/mock-text" },
                         entries: [{ role: "user", parts: [{ type: "text", text: "raw" }] }] } }
    assert_response :accepted
    assert_equal "Be brief.", response.parsed_body.dig("input", "instructions")

    post conversation_inputs_path(conversation), headers: auth("s-4"), as: :json,
      params: { input: { kind: "direct_reply", text: "x", instructions: "Be brief.",
                         model: { model: "dev/mock-text" } } }
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
  end

  test "the closed history vocabulary refuses malformed shapes at the boundary" do
    conversation = create_conversation!

    [
      { max_entires: 5 },
      { positions: [1, 2] },
      [{ max_entries: 1 }],
      [],
      "bare",
      { token_budget_share: 1.0e-10 },
    ].each do |bad|
      post conversation_inputs_path(conversation),
        headers: auth("hb-#{bad.hash}"), as: :json,
        params: { input: { kind: "direct_reply", text: "q",
                           model: { model: "dev/mock-text" }, history: bad } }
      assert_response :bad_request, bad.inspect
      assert_equal "parameter_invalid", response.parsed_body.dig("error", "code"),
        "a typo'd or malformed bound refuses loudly — never a silent strip: #{bad.inspect}"
    end
    assert_equal 0, ConversationInput.count

    post conversation_context_estimate_path(conversation), headers: auth, as: :json,
      params: { context_estimate: { prompt: "p", model: { model: "dev/mock-text" },
                                    history: { max_entires: 5 } } }
    assert_response :bad_request,
      "the estimate surface refuses the same typo instead of estimating unbounded"
  end

  # Every optional-field root reads through Strong Parameters: a scalar
  # where the object should be is the family's 400, never a 500.
  test "a scalar root on the input, turn, edit and variant doors is 400 parameter_missing" do
    conversation = create_conversation!
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    turn_path = "#{conversation_turns_path(conversation)}/#{seam.turn.public_id}"
    post conversation_inputs_path(conversation), headers: auth("s-1"), as: :json, params: { input: { text: "held" } }
    input_public_id = response.parsed_body.dig("input", "public_id")

    [
      [:post, conversation_inputs_path(conversation), { input: "text" }],
      [:patch, "#{conversation_inputs_path(conversation)}/#{input_public_id}", { input: "text" }],
      [:patch, turn_path, { turn: "hidden" }],
      [:post, "#{turn_path}/edit", { edit: "text" }],
      [:patch, "#{turn_path}/variants/#{seam.turn.active_variant.public_id}", { variant: "hidden" }],
    ].each do |verb, path, body|
      public_send(verb, path, headers: auth(SecureRandom.uuid), as: :json, params: body)
      assert_response :bad_request, "#{verb.upcase} #{path}"
      assert_equal "parameter_missing", response.parsed_body.dig("error", "code"), "#{verb.upcase} #{path}"
    end
  end

  # THE CLOCK AT THE DOOR OVER HTTP: `deliver_at` (ISO 8601 WITH an offset) or `deliver_in` (a
  # delay) through the ONE parser, on create and on PATCH; a malformed value is `400
  # parameter_invalid` naming its field, both at once `422 deliver_at_ambiguous`; the door's bounds
  # and the steer conjunct answer 422 by name; the listing shows the row's time; an absent pair on
  # PATCH keeps it, `deliver_in: "0s"` makes the row due now.
  test "deliver_at and deliver_in ride create and PATCH through the one parser, with the refusals by name" do
    conversation = create_conversation!(title: "timed")
    before = Time.current
    post conversation_inputs_path(conversation), headers: auth("d-1"), as: :json,
      params: { input: { text: "later", deliver_in: "20m" } }
    assert_response :accepted
    row = response.parsed_body.fetch("input")
    at = Time.iso8601(row.fetch("deliver_at"))
    assert_in_delta before + 20.minutes, at, 5, "the delay is resolved against the kernel's clock"
    input_public_id = row.fetch("public_id")
    assert_equal at, ConversationInput.find_by!(public_id: input_public_id).deliver_at

    get conversation_inputs_path(conversation), headers: auth
    assert_equal row.fetch("deliver_at"), response.parsed_body.fetch("inputs").sole.fetch("deliver_at"),
      "the listing shows the row's time"

    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}", headers: auth, as: :json,
      params: { input: { text: "later, edited" } }
    assert_response :success
    assert_equal row.fetch("deliver_at"), response.parsed_body.dig("input", "deliver_at"), "absent keeps the time"

    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}", headers: auth, as: :json,
      params: { input: { deliver_at: "2027-01-01T09:00:00+08:00" } }
    assert_response :success
    assert_equal Time.utc(2027, 1, 1, 1), Time.iso8601(response.parsed_body.dig("input", "deliver_at")),
      "an absolute time with an offset reschedules, held in UTC"

    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}", headers: auth, as: :json,
      params: { input: { deliver_in: "0s" } }
    assert_response :success
    assert_operator Time.iso8601(response.parsed_body.dig("input", "deliver_at")), :<=, Time.current + 1,
      "`0s` is the clear: due now"

    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}", headers: auth, as: :json,
      params: { input: { deliver_at: "2020-01-01T00:00:00Z" } }
    assert_response :unprocessable_entity, "the same two bounds on the edit"
    assert_equal "deliver_at_in_past", response.parsed_body.dig("error", "code")

    patch "#{conversation_inputs_path(conversation)}/#{input_public_id}", headers: auth, as: :json,
      params: { input: { deliver_at: "2026-09-16T09:00:00" } }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    assert_match(/deliver_at/, response.parsed_body.dig("error", "message"), "a naive time names its field")

    post conversation_inputs_path(conversation), headers: auth("d-2"), as: :json,
      params: { input: { text: "x", deliver_at: "2026-09-16T09:00:00" } }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    assert_match(/deliver_at/, response.parsed_body.dig("error", "message"))

    post conversation_inputs_path(conversation), headers: auth("d-3"), as: :json,
      params: { input: { text: "x", deliver_in: "soon" } }
    assert_response :bad_request
    assert_match(/deliver_in/, response.parsed_body.dig("error", "message"), "junk names its field")

    post conversation_inputs_path(conversation), headers: auth("d-4"), as: :json,
      params: { input: { text: "x", deliver_at: "2027-01-01T00:00:00Z", deliver_in: "1h" } }
    assert_response :unprocessable_entity
    assert_equal "deliver_at_ambiguous", response.parsed_body.dig("error", "code")

    post conversation_inputs_path(conversation), headers: auth("d-5"), as: :json,
      params: { input: { text: "x", delivery_mode: "steer", deliver_in: "1h" } }
    assert_response :unprocessable_entity
    assert_equal "deliver_at_not_steerable", response.parsed_body.dig("error", "code")

    post conversation_inputs_path(conversation), headers: auth("d-6"), as: :json,
      params: { input: { text: "x", deliver_at: "2020-01-01T00:00:00Z" } }
    assert_response :unprocessable_entity
    assert_equal "deliver_at_in_past", response.parsed_body.dig("error", "code")

    post conversation_inputs_path(conversation), headers: auth("d-7"), as: :json,
      params: { input: { text: "x", deliver_at: "2099-01-01T00:00:00Z" } }
    assert_response :unprocessable_entity
    assert_equal "deliver_at_too_far", response.parsed_body.dig("error", "code")
    assert_equal 1, conversation.conversation_inputs.count, "every refusal posts nothing"
  end

  test "relative scheduled input retries preserve the first deadline after time advances" do
    conversation = create_conversation!(title: "timed")
    accepted_at = Time.current.floor
    body = { input: { text: "later", deliver_in: "20m" } }
    first = nil
    travel_to accepted_at do
      post conversation_inputs_path(conversation), headers: auth("relative-key"), as: :json, params: body
      assert_response :accepted
      assert_equal "false", response.headers["Idempotency-Replayed"]
      first = response.parsed_body
      assert_equal accepted_at + 20.minutes, Time.iso8601(first.dig("input", "deliver_at"))
    end

    [2.seconds, 21.minutes].each do |elapsed|
      travel_to accepted_at + elapsed do
        post conversation_inputs_path(conversation), headers: auth("relative-key"), as: :json, params: body
        assert_response :accepted
        assert_equal "true", response.headers["Idempotency-Replayed"]
        assert_equal first, response.parsed_body
      end
    end

    post conversation_inputs_path(conversation), headers: auth("relative-key"), as: :json,
      params: { input: { text: "later", deliver_in: "1200s" } }
    assert_response :accepted, "equivalent durations express the same intent"
    assert_equal first, response.parsed_body

    post conversation_inputs_path(conversation), headers: auth("relative-key"), as: :json,
      params: { input: { text: "later", deliver_in: "21m" } }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
    assert_equal 1, conversation.conversation_inputs.count
    assert_equal accepted_at + 20.minutes, conversation.conversation_inputs.sole.deliver_at
  end

  # Equivalent absolute instants share a digest; a different instant refuses.
  test "the resolved time is in the create envelope: a replay naming another time is a mismatch" do
    conversation = create_conversation!(title: "timed")
    post conversation_inputs_path(conversation), headers: auth("d-key"), as: :json,
      params: { input: { text: "later", deliver_at: "2027-01-01T00:00:00Z" } }
    assert_response :accepted
    accepted = response.parsed_body.dig("input", "public_id")

    post conversation_inputs_path(conversation), headers: auth("d-key"), as: :json,
      params: { input: { text: "later", deliver_at: "2027-01-01T08:00:00+08:00" } }
    assert_response :accepted
    assert_equal accepted, response.parsed_body.dig("input", "public_id"),
      "the same instant spelled in another zone is the same word: the canonical string is digested"

    post conversation_inputs_path(conversation), headers: auth("d-key"), as: :json,
      params: { input: { text: "later", deliver_at: "2027-01-02T00:00:00Z" } }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
    assert_equal 1, conversation.conversation_inputs.count
  end

  # THE PICTURES ON THE WIRE: `attachments` beside `text` — canonical ids in the idempotency
  # envelope, refused at the parameter boundary when malformed or beside `entries`, typed 422 on a
  # steer, the presenter naming each picture; PATCH without `attachments` keeps them.
  test "attachments ride the input door and its envelope on both hosts, and PATCH keeps them" do
    conversation = create_conversation!
    png = Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
    picture = @account.content_uploads.create!(
      creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png), filename: "diagram.png",
        content_type: "image/png")
    )

    post conversation_inputs_path(conversation), headers: auth("att-1"), as: :json,
      params: { input: { text: "look", attachments: [picture.public_id] } }
    assert_response :accepted
    input = response.parsed_body.fetch("input")
    assert_equal "look", input["text"]
    assert_equal [{ "public_id" => picture.public_id, "filename" => "diagram.png",
                    "content_type" => "image/png", "byte_size" => 70 }], input["attachments"]

    post conversation_inputs_path(conversation), headers: auth("att-1"), as: :json,
      params: { input: { text: "look" } }
    assert_response :conflict, "the set is in the digest: a replay naming another is a mismatch"

    post conversation_inputs_path(conversation), headers: auth("att-2"), as: :json,
      params: { input: { text: "look", attachments: ["not-a-uuid"] } }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    post conversation_inputs_path(conversation), headers: auth("att-3"), as: :json,
      params: { input: { entries: [{ text: "raw" }], attachments: [picture.public_id] } }
    assert_response :bad_request
    post conversation_inputs_path(conversation), headers: auth("att-4"), as: :json,
      params: { input: { text: "steer", delivery_mode: "steer", attachments: [picture.public_id] } }
    assert_response :unprocessable_entity
    assert_equal "attachments_not_steerable", response.parsed_body.dig("error", "code")

    patch "#{conversation_inputs_path(conversation)}/#{input["public_id"]}", headers: auth, as: :json,
      params: { input: { text: "better" } }
    assert_response :success
    assert_equal [picture.public_id], response.parsed_body.dig("input", "attachments").map { |a| a["public_id"] },
      "absent attachments keeps the binding"
    patch "#{conversation_inputs_path(conversation)}/#{input["public_id"]}", headers: auth, as: :json,
      params: { input: { attachments: [] } }
    assert_response :success
    assert_nil response.parsed_body.dig("input", "attachments"), "[] unbinds"

    get conversation_inputs_path(conversation), headers: auth
    assert_response :success
    assert_equal ["better"], response.parsed_body.fetch("inputs").map { |row| row["text"] }
  end

  # THE ADDRESSEE ON THE WIRE: `answering_user_public_id` on the input door — the create door's word
  # — an address (@handle or public id) resolved at the door, in the idempotency envelope, and
  # create-only: PATCH drops it by permit.
  test "answering_user_public_id rides the input door and its envelope, and is ignored on PATCH" do
    agent = users(:agent)
    conversation = create_conversation!(title: "room")

    post conversation_inputs_path(conversation), headers: auth("to-1"), as: :json,
      params: { input: { text: "B, your view?", answering_user_public_id: "@#{agent.handle}" } }
    assert_response :accepted, response.body
    input = ConversationInput.find_by!(public_id: response.parsed_body.dig("input", "public_id"))
    assert_equal agent, input.answering_user

    post conversation_inputs_path(conversation), headers: auth("to-1"), as: :json,
      params: { input: { text: "B, your view?", answering_user_public_id: @human.public_id } }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code"),
      "another addressee under the same key is a different envelope"

    post conversation_inputs_path(conversation), headers: auth("to-2"), as: :json,
      params: { input: { text: "hello?", answering_user_public_id: "@nobody-here" } }
    assert_response :unprocessable_content
    assert_equal "principal_unknown", response.parsed_body.dig("error", "code")

    patch "#{conversation_inputs_path(conversation)}/#{input.public_id}", headers: auth, as: :json,
      params: { input: { text: "B, your view, please?", answering_user_public_id: @human.public_id } }
    assert_response :ok, response.body
    assert_equal agent, input.reload.answering_user, "create-only: the edit surface drops it by permit"
  end
end
