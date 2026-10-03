require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiConversationTurnsTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  # --- the timeline and its decks -------------------------------------

  def test_the_timeline_is_a_position_window_with_cursors_in_both_directions
    page = chat([[200, {}, contract.fetch("valid_turns_fixture")]]).turns.list(after_position: 3)

    assert_equal "#{PATH}/turns", request.fetch(:path)
    assert_equal({ "after_position" => 3 }, request.fetch(:params))
    assert_equal 0, page.before_position
    assert_equal 4, page.after_position

    turn = page.first
    assert_equal TURN_ID, turn.public_id
    refute_predicate turn, :inherited?
    refute_predicate turn, :compaction_summary?
    assert_equal "Here is the plan.", turn.text
    assert_predicate turn.active_variant, :active?
    assert_equal "dev", turn.active_variant.model.provider_id
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
      .turns.regenerate(TURN_ID, model: "dev/text")
    assert_equal "#{PATH}/turns/#{TURN_ID}/regeneration", request.fetch(:path)
    assert_equal "running", regenerated.turn_status
    refute_predicate regenerated.variant, :active?,
      "the original stays rendered until the new sample settles"
  end

  def test_edit_demands_exactly_one_content_spelling
    assert_raises(ArgumentError) { chat([]).turns.edit(TURN_ID) }
    assert_raises(ArgumentError) { chat([]).turns.edit(TURN_ID, text: "a", entries: []) }
  end

  # A reply the kernel's loop produced names its loop and carries the
  # loop's rounds as summary rows, both read by presence; a direct reply
  # carries neither, and the two are told apart by `loop_backed?`, never
  # by matching `source` against a list.
  def test_a_loop_backed_turn_names_its_loop_and_carries_its_rounds
    turn = chat([[200, {}, contract.fetch("valid_turns_fixture")]]).turns.list.first
    variant = turn.active_variant

    assert_equal "agent_loop", variant.source
    assert_predicate variant, :loop_backed?
    assert_equal "01900000-0000-7000-8000-0000000000b1", variant.agent_loop_public_id
    round = variant.rounds.fetch(0)
    assert_equal "r1", round.fetch("task_key")
    assert_equal contract.fetch("variant_round_projection"), round.keys,
      "the round row is the loop transcript's row without its calls, carried as the transcript carries it"
    %w[continue spine calls branches].each { |word| refute round.key?(word), "never a DAG word on a turn: #{word}" }
    assert_equal "Here is the plan.", turn.text, "the deliverable's answer is the content, as on a direct reply"
    assert_equal variant.agent_loop_public_id, variant.to_h.fetch(:agent_loop_public_id)

    body = contract.fetch("valid_turns_fixture")
    direct = body.fetch("turns").first.fetch("active_variant")
      .merge("source" => "inference").except("agent_loop_public_id", "rounds")
    plain = chat([[200, {}, body.merge("turns" => [body.fetch("turns").first.merge("active_variant" => direct)])]])
      .turns.list.first.active_variant
    refute_predicate plain, :loop_backed?
    assert_nil plain.agent_loop_public_id
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
  # back running; with a loop-backed reply in flight, that reply and the
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
    assert_equal "task_not_queued", error.code, "the loop's vocabulary reaches the caller as it is"
  end

  # THE LIFT: a loop-backed turn regenerates as a new candidate
  # with its OWN loop — the 202 names it, so the feed's correlation key is
  # on the answer; the old candidate keeps its loop. The typed 409 this
  # test once pinned is gone; the one refusal left is the adjudication hold.
  def test_regenerating_a_loop_backed_turn_answers_a_loop_backed_sibling_with_its_own_loop
    regeneration = chat([[202, {}, contract.fetch("valid_loop_backed_regeneration_fixture")]])
      .turns.regenerate(TURN_ID)

    assert_equal "#{PATH}/turns/#{TURN_ID}/regeneration", request.fetch(:path)
    assert_equal "running", regeneration.turn_status
    sibling = regeneration.variant
    assert_equal "agent_loop", sibling.source
    assert_predicate sibling, :loop_backed?
    assert_equal "01900000-0000-7000-8000-0000000000b2", sibling.agent_loop_public_id
    assert_equal ["r1"], sibling.rounds.map { |round| round.fetch("task_key") }, "the rebuilt seed, waiting"
    assert_predicate sibling.world, :untouched?, "nothing has run behind the new candidate"
    refute_predicate sibling, :active?

    error = assert_raises(CybrosAgent::Api::Error) do
      chat([[409, {}, { "error" => { "code" => "loop_needs_attention", "message" => "Refused" } }]])
        .turns.regenerate(TURN_ID)
    end
    assert_equal "loop_needs_attention", error.code
  end

  # THE WORLD ON THE DECK: a loop-backed variant's derived fact, read
  # by presence; `checkpoint` carries the value the runner stored verbatim
  # (`raw`) and the facts this gem reads off it as members.
  def test_a_loop_backed_variant_carries_the_world_and_reads_the_checkpoint_hash_without_shaping_the_value
    turn = chat([[200, {}, contract.fetch("valid_turns_fixture")]]).turns.list.first
    world = turn.active_variant.world
    expected = contract.fetch("world_fixtures").fetch("touched")
    assert_predicate world, :touched?
    assert_equal [expected.fetch("loop"), expected.fetch("runner")], [world.loop, world.runner]
    assert_equal expected.fetch("checkpoint"), world.checkpoint.raw
    assert_equal expected.dig("checkpoint", "hash"), world.checkpoint_hash
    assert_equal expected.dig("checkpoint", "store"), world.checkpoint.store
    assert_nil world.skipped
    assert_equal expected, world.to_h.transform_keys(&:to_s)

    deck_body = contract.fetch("valid_variants_fixture")
    with_world = ->(value) {
      variant = deck_body.fetch("variants").first.merge("world" => value)
      chat([[200, {}, deck_body.merge("variants" => [variant])]]).turns.variants(TURN_ID).items.first.world
    }
    skipped = with_world.call(contract.fetch("world_fixtures").fetch("skipped"))
    assert_predicate skipped, :touched?
    assert_nil skipped.checkpoint_hash, "no hash: the runner declined to capture"
    assert_equal "tree_too_large", skipped.skipped
    placeholder = with_world.call(contract.fetch("world_fixtures").fetch("placeholder"))
    assert_equal "c1", placeholder.checkpoint.raw, "a non-Hash rides verbatim"
    assert_nil placeholder.checkpoint_hash
    assert_nil placeholder.skipped
    untouched = with_world.call(contract.fetch("world_fixtures").fetch("untouched"))
    assert_predicate untouched, :untouched?
    assert_nil untouched.loop
    assert_nil untouched.checkpoint
    assert_equal({ status: "untouched" }, untouched.to_h)

    direct = deck_body.fetch("variants").first.except("agent_loop_public_id", "rounds", "world")
    plain = chat([[200, {}, deck_body.merge("variants" => [direct])]]).turns.variants(TURN_ID).items.first
    assert_nil plain.world
    refute plain.to_h.key?(:world), "absent stays absent"
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
  # A loop-backed variant answers its first round's; a variant whose reply
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
