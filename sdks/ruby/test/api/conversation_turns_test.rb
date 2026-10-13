require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiConversationTurnsTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  # --- the timeline and its decks -------------------------------------

  def test_stored_reasoning_reads_a_candidate_window_with_model_identity_and_optional_text
    body = {
      "items" => [
        { "task_key" => "r2", "model" => { "provider_id" => "dev", "model_ref" => "reasoner" },
          "available" => true, "text" => "A retained explanation." },
        { "task_key" => "r3", "model" => { "provider_id" => "dev", "model_ref" => "plain" },
          "available" => false },
      ],
      "pagination" => { "next_before" => "opaque-next", "has_older" => true },
    }
    page = chat([[200, {}, body]]).turns.reasoning(TURN_ID, VARIANT_ID, before: "opaque-before", limit: 2)

    assert_equal "#{PATH}/turns/#{TURN_ID}/variants/#{VARIANT_ID}/reasoning", request.fetch(:path)
    assert_equal({ "before" => "opaque-before", "limit" => 2 }, request.fetch(:params))
    assert_equal "opaque-next", page.next_before
    assert_predicate page, :has_older?
    first, last = page.items
    assert_equal "r2", first.task_key
    assert_equal "reasoner", first.model.model_ref
    assert_predicate first, :available?
    assert_equal "A retained explanation.", first.text
    refute_predicate last, :available?
    refute last.to_h.key?(:text)
  end

  def test_direct_and_empty_reasoning_windows_have_no_task_cursor
    body = {
      "items" => [{ "model" => { "provider_id" => "dev", "model_ref" => "reasoner" },
                    "available" => true, "text" => "Direct reasoning." }],
      "pagination" => { "next_before" => nil, "has_older" => false },
    }
    page = chat([[200, {}, body]]).turns.reasoning(TURN_ID, VARIANT_ID)
    assert_nil page.items.first.task_key
    assert_nil page.next_before
    refute_predicate page, :has_older?
    page = chat([[200, {}, body.merge("items" => [])]]).turns.reasoning(TURN_ID, VARIANT_ID)
    assert_empty page.items
  end

  def test_the_timeline_is_a_position_window_with_cursors_in_both_directions
    page = chat([[200, {}, contract.fetch("valid_turns_fixture")]]).turns.list(after_position: 3)

    assert_equal "#{PATH}/turns", request.fetch(:path)
    assert_equal({ "after_position" => 3 }, request.fetch(:params))
    assert_equal 0, page.before_position
    assert_equal 4, page.after_position

    turn = page.first
    assert_equal TURN_ID, turn.public_id
    refute_predicate turn, :inherited?
    refute_predicate turn, :reference?
    refute_predicate turn, :compaction_summary?
    assert_equal "Here is the plan.", turn.text
    assert_predicate turn.active_variant, :active?
    assert_equal "dev", turn.active_variant.model.provider_id
  end

  def test_a_local_side_snapshot_preserves_its_reference_flag_without_a_backing_run
    body = contract.fetch("valid_turns_fixture")
    snapshot = contract.fetch("valid_reference_turn_fixture")
    turn = chat([[200, {}, body.merge("turns" => [snapshot])]]).turns.list.first

    assert_predicate turn, :reference?
    refute_predicate turn, :inherited?
    assert_equal true, turn.to_h.fetch(:reference)
    assert_nil turn.active_variant.run_public_id
    assert_equal "Here is the plan.", turn.text
  end

  def test_the_two_position_cursors_are_mutually_exclusive
    assert_raises(ArgumentError) do
      chat([]).turns.list(after_position: 1, before_position: 9)
    end
  end

  def test_hidden_turns_can_be_requested_without_changing_the_position_window
    body = contract.fetch("valid_turns_fixture")
    body = body.merge("turns" => [body.fetch("turns").first.merge("visibility" => "hidden")])
    page = chat([[200, {}, body]]).turns.list(include_hidden: true, before_position: 8, limit: 1)

    assert_equal({ "include_hidden" => true, "before_position" => 8, "limit" => 1 }, request.fetch(:params))
    assert_equal "hidden", page.first.visibility
    assert_equal TURN_ID, page.first.public_id
  end

  def test_hidden_turns_can_be_explicitly_excluded
    chat([[200, {}, contract.fetch("valid_turns_fixture")]]).turns.list(include_hidden: false)

    assert_equal({ "include_hidden" => false }, request.fetch(:params))
  end

  # A turn whose only candidate was concealed, or whose reply failed before
  # producing one, renders no `active_variant` — read by presence.
  def test_a_turn_without_an_active_variant_reads_as_nil
    body = contract.fetch("valid_turns_fixture")
    body = body.merge("turns" => [body.fetch("turns").first.except("active_variant")])
    turn = chat([[200, {}, body]]).turns.list.first

    assert_nil turn.active_variant
    assert_nil turn.text
  end

  def test_edit_and_regenerate_both_ADD_to_the_deck
    variant = chat([[200, {}, contract.fetch("valid_variant_fixture")]])
      .turns.edit(TURN_ID, text: "corrected")
    assert_equal "#{PATH}/turns/#{TURN_ID}/edit", request.fetch(:path)
    assert_equal "corrected", request.fetch(:body).fetch("edit").fetch("text")
    assert_predicate variant, :active?

    regenerated = chat([[202, {}, contract.fetch("valid_regeneration_fixture")]])
      .turns.regenerate(TURN_ID, idempotency_key: SecureRandom.uuid, model: "dev/text")
    assert_equal "#{PATH}/turns/#{TURN_ID}/regeneration", request.fetch(:path)
    assert_equal "running", regenerated.turn_status
    refute_predicate regenerated.variant, :active?,
      "the original stays rendered until the new sample settles"
  end

  def test_edit_demands_exactly_one_content_spelling
    assert_raises(ArgumentError) { chat([]).turns.edit(TURN_ID) }
    assert_raises(ArgumentError) { chat([]).turns.edit(TURN_ID, text: "a", entries: []) }
  end

  def test_regeneration_requires_a_caller_key_and_reports_the_replayed_acceptance
    error = assert_raises(ArgumentError) { chat([]).turns.regenerate(TURN_ID, idempotency_key: "") }
    assert_match(/idempotency_key/, error.message)

    acceptance = contract.fetch("valid_regeneration_fixture")
    result = chat([[202, { "Idempotency-Replayed" => "true" }, acceptance]])
      .turns.regenerate(TURN_ID, idempotency_key: "saved-regeneration")
    assert_equal "saved-regeneration", request.fetch(:headers).fetch("Idempotency-Key")
    assert_predicate result, :replayed?
    assert_equal acceptance.dig("variant", "public_id"), result.variant.public_id
  end

  def test_regeneration_receipt_reads_the_retained_acceptance_and_preserves_missing_or_unknown_errors
    acceptance = contract.fetch("valid_regeneration_fixture")
    result = chat([[200, {}, acceptance]]).turns.regeneration_receipt(idempotency_key: "saved-regeneration")
    assert_equal :get, request.fetch(:method)
    assert_equal "#{PATH}/regeneration_receipt", request.fetch(:path)
    assert_equal({ "idempotency_key" => "saved-regeneration" }, request.fetch(:params))
    assert_equal acceptance.dig("variant", "public_id"), result.variant.public_id
    assert_predicate result, :replayed?

    assert_raises(CybrosAgent::Api::NotFound) do
      chat([[404, {}, { "error" => { "code" => "not_found" } }]])
        .turns.regeneration_receipt(idempotency_key: "missing")
    end
    assert_raises(CybrosAgent::Api::Error) do
      chat([[503, {}, { "error" => { "code" => "unavailable" } }]])
        .turns.regeneration_receipt(idempotency_key: "unknown")
    end
  end

  # A reply the kernel's run produced names its run and carries the
  # run's rounds as summary rows, both read by presence; a direct reply
  # carries neither, and the two are told apart by `run_backed?`, never
  # by matching `source` against a list.
  def test_a_run_backed_turn_names_its_run_and_carries_its_rounds
    turn = chat([[200, {}, contract.fetch("valid_turns_fixture")]]).turns.list.first
    variant = turn.active_variant

    assert_equal "run", variant.source
    assert_predicate variant, :run_backed?
    assert_equal "01900000-0000-7000-8000-0000000000b1", variant.run_public_id
    round = variant.rounds.fetch(0)
    assert_equal "r1", round.fetch("task_key")
    assert_equal contract.fetch("variant_round_projection"), round.keys,
      "the round row is the run transcript's row without its calls, carried as the transcript carries it"
    %w[continue mainline calls branches].each { |word| refute round.key?(word), "never a DAG word on a turn: #{word}" }
    assert_equal "Here is the plan.", turn.text, "the deliverable's answer is the content, as on a direct reply"
    assert_equal variant.run_public_id, variant.to_h.fetch(:run_public_id)

    body = contract.fetch("valid_turns_fixture")
    direct = body.fetch("turns").first.fetch("active_variant")
      .merge("source" => "inference").except("run_public_id", "rounds")
    plain = chat([[200, {}, body.merge("turns" => [body.fetch("turns").first.merge("active_variant" => direct)])]])
      .turns.list.first.active_variant
    refute_predicate plain, :run_backed?
    assert_nil plain.run_public_id
    assert_nil plain.rounds
    refute plain.to_h.key?(:rounds), "absent stays absent"
  end

  # THE WORDS THAT OPENED A REPLY: a reply turn's variant carries its seed as
  # `prompt_text`, beside the reply's `content`; a message turn carries
  # none — its `content` is the person's words — and nil stays absent.
  def test_a_reply_turns_variant_carries_the_prompt_text_that_opened_it_and_a_message_turn_carries_none
    body = contract.fetch("valid_turns_fixture")
    turn = chat([[200, {}, body]]).turns.list.first
    assert_equal "direct_reply", turn.kind
    assert_equal "What is next?", turn.active_variant.prompt_text, "the seed's words"
    assert_equal "Here is the plan.", turn.text, "beside the reply's content"
    assert_equal "What is next?", turn.active_variant.to_h.fetch(:prompt_text)

    message = body.fetch("turns").first.merge("kind" => "message", "role" => "user",
      "active_variant" => body.fetch("turns").first.fetch("active_variant").except("prompt_text"))
    variant = chat([[200, {}, body.merge("turns" => [message])]]).turns.list.first.active_variant
    assert_nil variant.prompt_text
    refute variant.to_h.key?(:prompt_text), "absent stays absent"
  end

  # COMPACT NOW, on either host: idle, the summary turn comes
  # back running; with a run-backed reply in flight, that reply and the
  # round the kernel repaired beside it — read by presence, so the
  # between-turn answer is unchanged.
  def test_compact_posts_the_model_and_reads_the_turn_and_the_mid_turn_repair_by_presence
    turn = { "public_id" => "t-9", "position" => 9, "kind" => "compaction_summary", "status" => "running" }
    idle = chat([[202, {}, { "turn" => turn }]]).compact(model: "dev/summary")

    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/compaction", request.fetch(:path)
    assert_equal({ "compaction" => { "model" => "dev/summary" } }, request.fetch(:body))
    assert_equal "compaction_summary", idle.kind
    assert_equal "running", idle.turn_status
    assert_nil idle.task_key
    assert_nil idle.summary_task_key
    refute_predicate idle, :mid_turn?

    running = { "public_id" => "t-8", "position" => 8, "kind" => "direct_reply", "status" => "running" }
    repaired = chat([[202, {}, { "turn" => running, "task" => { "key" => "r7", "status" => "waiting" },
                                 "summary_task_key" => "k1" }]]).compact
    assert_equal({ "compaction" => {} }, request.fetch(:body), "unnamed, the model is the conversation's own")
    assert_equal "r7", repaired.task_key
    assert_equal "k1", repaired.summary_task_key
    assert_predicate repaired, :mid_turn?

    error = assert_raises(CybrosAgent::Api::Error) do
      chat([[409, {}, { "error" => { "code" => "task_not_queued", "message" => "Refused" } }]]).compact
    end
    assert_equal "task_not_queued", error.code, "the run's vocabulary reaches the caller as it is"
  end

  # THE LIFT: a run-backed turn regenerates as a new candidate
  # with its OWN run — the 202 names it, so the feed's correlation key is
  # on the answer; the old candidate keeps its run. The typed 409 this
  # test once pinned is gone; the one refusal left is the adjudication hold.
  def test_regenerating_a_run_backed_turn_answers_a_run_backed_sibling_with_its_own_run
    regeneration = chat([[202, {}, contract.fetch("valid_run_backed_regeneration_fixture")]])
      .turns.regenerate(TURN_ID, idempotency_key: SecureRandom.uuid)

    assert_equal "#{PATH}/turns/#{TURN_ID}/regeneration", request.fetch(:path)
    assert_equal "running", regeneration.turn_status
    sibling = regeneration.variant
    assert_equal "run", sibling.source
    assert_predicate sibling, :run_backed?
    assert_equal "01900000-0000-7000-8000-0000000000b2", sibling.run_public_id
    assert_equal ["r1"], sibling.rounds.map { |round| round.fetch("task_key") }, "the rebuilt seed, waiting"
    assert_predicate sibling.runner_effects, :untouched?, "nothing has run behind the new candidate"
    refute_predicate sibling, :active?

    error = assert_raises(CybrosAgent::Api::Error) do
      chat([[409, {}, { "error" => { "code" => "run_needs_attention", "message" => "Refused" } }]])
        .turns.regenerate(TURN_ID, idempotency_key: SecureRandom.uuid)
    end
    assert_equal "run_needs_attention", error.code
  end

  def test_run_variants_preserve_each_runner_checkpoint_and_its_absence
    deck_body = contract.fetch("valid_variants_fixture")
    effect = ->(value) {
      variant = deck_body.fetch("variants").first.merge("runner_effects" => value)
      chat([[200, {}, deck_body.merge("variants" => [variant])]]).turns.variants(TURN_ID).items.first.runner_effects
    }
    facts = contract.fetch("runner_effects_fixtures")
    touched = effect.call(facts.fetch("touched"))
    assert_predicate touched, :touched?
    expected = facts.fetch("touched").fetch("runners").first
    row = touched.runners.first
    assert_equal expected.fetch("runner_executor_public_id"), row.runner_executor_public_id
    assert_equal expected.fetch("run_public_id"), row.run_public_id
    assert_equal expected.fetch("task_key"), row.task_key
    assert_equal expected.fetch("checkpoint"), row.checkpoint.raw
    assert_equal expected.dig("checkpoint", "hash"), row.checkpoint_hash
    assert_equal expected.dig("checkpoint", "store"), row.checkpoint.store
    assert_nil row.skipped
    skipped = effect.call(facts.fetch("skipped")).runners.first
    assert_nil skipped.checkpoint_hash
    assert_equal "tree_too_large", skipped.skipped
    placeholder = effect.call(facts.fetch("placeholder")).runners.first
    assert_equal "c1", placeholder.checkpoint.raw
    assert_nil placeholder.checkpoint_hash
    assert_nil placeholder.skipped
    untouched = effect.call(facts.fetch("untouched"))
    assert_predicate untouched, :untouched?
    assert_equal({ status: "untouched", runners: [] }, untouched.to_h)
    direct = deck_body.fetch("variants").first.except("run_public_id", "rounds", "runner_effects")
    plain = chat([[200, {}, deck_body.merge("variants" => [direct])]]).turns.variants(TURN_ID).items.first
    assert_nil plain.runner_effects
    refute plain.to_h.key?(:runner_effects)
  end

  def test_the_deck_names_its_active_candidate_and_the_swipe_switches_it
    deck = chat([[200, {}, contract.fetch("valid_variants_fixture")]]).turns.variants(TURN_ID)

    assert_equal "#{PATH}/turns/#{TURN_ID}/variants", request.fetch(:path)
    assert_equal VARIANT_ID, deck.active.public_id
    refute deck.turn_inherited

    chat([[200, {}, contract.fetch("valid_variant_fixture")]]).turns.activate(TURN_ID, VARIANT_ID)
    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/turns/#{TURN_ID}/variants/#{VARIANT_ID}/activation",
      request.fetch(:path)
  end

  # THE DEBUG DOOR: the bytes a variant's request was
  # sealed with — EXACTLY the entries and the request options, derived from
  # the sealed body and never re-assembled — for reading what a model saw.
  # A run-backed variant answers its first round's; a variant whose reply
  # never minted is the kernel's 404 `request_not_sealed`.
  def test_the_sealed_request_read_answers_exactly_the_entries_and_the_options
    fixture = contract.fetch("valid_request_fixture")
    sealed = chat([[200, {}, fixture]]).turns.request(TURN_ID, VARIANT_ID)

    assert_equal :get, request.fetch(:method)
    assert_equal "#{PATH}/turns/#{TURN_ID}/variants/#{VARIANT_ID}/request", request.fetch(:path)
    assert_instance_of CybrosAgent::Api::SealedRequest, sealed
    assert_equal %i[entries request_options], sealed.to_h.keys, "two keys, nothing derived"
    assert_equal fixture.dig("request", "entries"), sealed.entries
    assert_equal fixture.dig("request", "request_options"), sealed.request_options
    assert_equal "system", sealed.entries.first.fetch("role"), "the slots lead the sealed list"
    assert_predicate sealed.entries, :frozen?

    error = assert_raises(CybrosAgent::Api::NotFound) do
      chat([[404, {}, { "error" => { "code" => "request_not_sealed", "message" => "no request" } }]])
        .turns.request(TURN_ID, VARIANT_ID)
    end
    assert_equal "request_not_sealed", error.code
  end

  # ONE CANDIDATE'S VIEW STATE: the kernel's PATCH on the
  # variant — `{variant: {concealed}}` — answered with the candidate as the
  # door renders it; the turn's own PATCH above hides the slot, this hides
  # a sample.
  def test_set_variant_view_state_patches_one_candidate_and_answers_it
    fixture = contract.fetch("valid_variant_fixture")
    written = chat([[200, {}, fixture]]).turns.set_variant_view_state(TURN_ID, VARIANT_ID, concealed: true)

    assert_equal :patch, request.fetch(:method)
    assert_equal "#{PATH}/turns/#{TURN_ID}/variants/#{VARIANT_ID}", request.fetch(:path)
    assert_equal({ "variant" => { "concealed" => true } }, request.fetch(:body))
    assert_instance_of CybrosAgent::Api::ConversationVariant, written
    assert_equal fixture.dig("variant", "public_id"), written.public_id

    chat([[200, {}, fixture]]).turns.set_variant_view_state(TURN_ID, VARIANT_ID, concealed: false)
    assert_equal({ "variant" => { "concealed" => false } }, request.fetch(:body), "a restore is the same field, false")

    error = assert_raises(CybrosAgent::Api::Conflict) do
      chat([[409, {}, { "error" => { "code" => "variant_active", "message" => "activate another first" } }]])
        .turns.set_variant_view_state(TURN_ID, VARIANT_ID, concealed: true)
    end
    assert_equal "variant_active", error.code, "the active candidate refuses; the kernel's word rides through"
  end

  def test_view_state_reports_whether_the_change_landed_on_an_override
    reference = chat([[200, {}, { "turn" => { "public_id" => TURN_ID, "inherited" => true } }]])
      .turns.set_view_state(TURN_ID, concealed: true)

    assert_equal :patch, request.fetch(:method)
    assert_predicate reference, :inherited?,
      "an inherited turn's view state writes an override — the ancestor's row is never touched"
  end

  def test_view_state_refuses_an_empty_change
    assert_raises(ArgumentError) { chat([]).turns.set_view_state(TURN_ID) }
  end
end
