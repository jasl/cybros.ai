require_relative "../test_helper"
require_relative "../support/ops_harness"

# Conversation rewind, regeneration, variants and paginated turn replay.
class OpsHistoryTest < Minitest::Test
  include RhoTest::OpsHarness

  # ---- rewind / regenerate: the composition behind the verbs --

  REWIND_RUNNER = "0199-runner".freeze
  TOUCHED_WORLD = { "status" => "touched", "loop" => "L1", "runner" => REWIND_RUNNER,
                    "checkpoint" => { "hash" => "H1", "store" => "S1" } }.freeze
  # The world_restore request's terminal task: completed, its metadata
  # naming the undo on the reserved key.
  WORLD_RESTORE_DETAIL = {
    "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "world_restore",
    "on_failure" => "propagate", "visibility" => "visible", "result" => { "resolved" => true },
    "output" => "Restored 2 files to H1; undo with H3",
    "metadata" => { "checkpoint" => { "hash" => "H3", "store" => "S1" } },
    "created_at" => "2026-09-15T00:00:00Z",
  }.freeze

  def turn_row(public_id, position)
    { "public_id" => public_id, "position" => position, "kind" => "direct_reply", "role" => "assistant",
      "status" => "completed", "visibility" => "visible", "inherited" => false, "created_at" => "2026-09-15T00:00:00Z",
      "answering_user_public_id" => "0199-user" }
  end

  def variant_deck(turn, world)
    { "turn" => { "public_id" => turn },
      "variants" => [{ "public_id" => "v0", "source" => "agent_loop", "status" => "completed", "active" => true,
                       "agent_loop_public_id" => "al0", "world" => world }] }
  end

  def test_rewind_needs_a_conversation_and_a_turn
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new)

    no_conv = request(daemon, :post, "/conversations/rewind", token: bearer(daemon), body: { "turn" => "t0" })
    assert_equal "400", no_conv.code
    no_turn = request(daemon, :post, "/conversations/rewind", token: bearer(daemon), body: { "public_id" => "c-1" })
    assert_equal "400", no_turn.code
  end

  def test_pruned_execution_cannot_be_regenerated_or_mistaken_for_an_untouched_world
    world = { "status" => "unavailable", "reason" => "execution_details_pruned" }
    variants = variant_deck("t0", world)
    variants.fetch("variants").first["details_pruned_at"] = "2026-09-29T00:00:00Z"
    api = NexusDoubles::FakeAgentApi.new(turns: [turn_row("t0", 0)], fork_world: world,
      conversation_runner: REWIND_RUNNER, variants: variants)
    daemon = member_ready(boot, api)

    [false, true].each do |keep_world|
      response = request(daemon, :post, "/conversations/regenerate", token: bearer(daemon),
        body: { "public_id" => "c-1", "turn" => "t0", "keep_world" => keep_world })
      assert_equal "409", response.code, response.body
      assert_equal "execution_details_pruned", JSON.parse(response.body).dig("error", "code")
    end
    assert_empty api.regenerations
    assert_empty api.loop_creates

    response = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t0" })
    assert_equal "200", response.code, response.body
    assert_equal({ "status" => "unavailable", "reason" => "execution_details_pruned" },
      JSON.parse(response.body).dig("rewind", "world"))
    assert_empty api.loop_creates
  end

  def test_the_retained_timeline_keeps_full_text_and_the_pruned_marker
    variant = { "public_id" => "v0", "source" => "agent_loop", "status" => "completed",
      "content" => "The complete answer", "prompt_text" => "The original question", "agent_loop_public_id" => "L1",
      "details_pruned_at" => "2026-09-29T00:00:00Z" }
    api = NexusDoubles::FakeAgentApi.new(turns: [turn_row("t0", 0).merge("active_variant" => variant)])
    daemon = member_ready(boot, api)
    response = request(daemon, :get, "/conversations/turns?public_id=c-1", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    displayed = JSON.parse(response.body).fetch("turns").first.fetch("active_variant")
    assert_equal "The complete answer", displayed.fetch("content")
    assert_equal "The original question", displayed.fetch("prompt_text")
    assert_equal "2026-09-29T00:00:00Z", displayed.fetch("details_pruned_at")
  end

  # NOTHING WROTE above the turn: the fork alone, `untouched`, no request loop.
  def test_rewind_of_an_untouched_point_forks_and_restores_nothing
    api = NexusDoubles::FakeAgentApi.new(turns: [turn_row("t0", 0)])
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t0" })

    assert_equal "200", response.code, response.body
    world = JSON.parse(response.body).dig("rewind", "world")
    assert_equal "untouched", world.fetch("status")
    assert_equal "c-1-side", JSON.parse(response.body).dig("rewind", "conversation")
    assert_equal 1, api.forks.length, "the fork was made"
    assert_empty api.loop_creates, "no restore request loop for an untouched point"
  end

  # FORK, then the restore request loop on the child's bound runner.
  def test_rewind_forks_then_restores_the_world_through_the_childs_runner
    api = NexusDoubles::FakeAgentApi.new(turns: [turn_row("t0", 0)], fork_world: TOUCHED_WORLD,
      conversation_runner: REWIND_RUNNER, task_detail: WORLD_RESTORE_DETAIL)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t0" })

    assert_equal "200", response.code, response.body
    world = JSON.parse(response.body).dig("rewind", "world")
    assert_equal "restored", world.fetch("status")
    assert_equal "H1", world.fetch("checkpoint")
    assert_equal "H3", world.fetch("undo"), "the undo rides the restore task's metadata"
    authored = api.loop_creates.fetch(0).fetch("agent_loop")
    assert_equal "world_restore", authored.dig("steps", 0, "tool", "name")
    assert_equal({ "checkpoint" => "H1", "store" => "S1" }, authored.dig("steps", 0, "tool", "input"))
    assert(authored.fetch("approval_rules").all? { |rule| rule.fetch("origin") == "author" },
      "the restore's rules are re-addressed to the seed's origin")
  end

  # ANOTHER runner (or none) holds the tree: the fork made, no restore loop.
  def test_rewind_is_unavailable_when_the_binding_is_not_the_claimant
    api = NexusDoubles::FakeAgentApi.new(turns: [turn_row("t0", 0)], fork_world: TOUCHED_WORLD)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t0" })

    world = JSON.parse(response.body).dig("rewind", "world")
    assert_equal "unavailable", world.fetch("status")
    assert_equal "runner_mismatch", world.fetch("reason")
    assert_empty api.loop_creates, "no restore of a tree this binding cannot reach"
  end

  # A LOCAL REFUSAL: a running turn of this conversation, before any fork.
  def test_rewind_refuses_a_conversation_with_a_running_turn
    api = NexusDoubles::FakeAgentApi.new(conversation_busy: "t-running", turns: [turn_row("t0", 0)])
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t0" })

    assert_equal "409", response.code, response.body
    assert_equal "conversation_busy", JSON.parse(response.body).dig("error", "code")
    assert_empty api.forks, "refused before any fork"
  end

  def test_rewind_keep_world_forks_and_leaves_the_world
    api = NexusDoubles::FakeAgentApi.new(turns: [turn_row("t0", 0)], fork_world: TOUCHED_WORLD,
      conversation_runner: REWIND_RUNNER)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t0", "keep_world" => true })

    assert_equal "kept", JSON.parse(response.body).dig("rewind", "world", "status")
    assert_empty api.loop_creates, "--keep-world restores nothing"
  end

  # A conversation deeper than one index page (`TURN_PAGE`): a bare
  # position reads ONE row of the window, an id walks the index newest-
  # first, and the tail check reads the newest page — none of the three
  # is a 100-turn scan from the start that misses everything past it.
  DEEP_CONVERSATION = Rho::Extensions::Ops::TURN_PAGE + 50

  def deep_turns = (0...DEEP_CONVERSATION).map { |position| turn_row("t#{position}", position) }

  def test_rewind_resolves_a_position_past_the_first_page_by_a_one_row_window
    api = NexusDoubles::FakeAgentApi.new(turns: deep_turns)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "120" })

    assert_equal "200", response.code, response.body
    assert_equal ["t120", 120], JSON.parse(response.body).fetch("rewind").values_at("forked_from", "position")
    assert_equal [{ "after_position" => 119, "limit" => 1 }], api.turn_windows, "one row: the row after 119"

    first = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "0" })
    assert_equal "200", first.code, first.body
    assert_equal({ "limit" => 1 }, api.turn_windows.last, "position 0 is the index's first row")

    missing = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => DEEP_CONVERSATION.to_s })
    assert_equal "404", missing.code
    assert_equal "turn_not_found", JSON.parse(missing.body).dig("error", "code")
  end

  def test_rewind_resolves_an_id_past_the_first_page_by_walking_newest_first
    api = NexusDoubles::FakeAgentApi.new(turns: deep_turns)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t20" })

    assert_equal "200", response.code, response.body
    assert_equal ["t20", 20], JSON.parse(response.body).fetch("rewind").values_at("forked_from", "position")
    assert_equal [{ "before_position" => Rho::Extensions::Ops::TURN_POSITION_CEILING, "limit" => 100 },
                  { "before_position" => 50, "limit" => 100 }], api.turn_windows,
      "the newest page first (t50..t149), then the page before it"

    missing = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t-never" })
    assert_equal "404", missing.code
    assert_equal "turn_not_found", JSON.parse(missing.body).dig("error", "code")
    assert_equal 4, api.turn_windows.length, "the miss walks the full page and the short one, then stops"
  end

  # REGENERATE's tail is the NEWEST row, past any page depth.
  def test_regenerate_finds_the_tail_of_a_deep_conversation
    tail = "t#{DEEP_CONVERSATION - 1}"
    api = NexusDoubles::FakeAgentApi.new(turns: deep_turns, variants: variant_deck(tail, { "status" => "untouched" }))
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/conversations/regenerate", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => tail })

    assert_equal "200", response.code, response.body
    assert_equal 1, api.regenerations.length, "the door regenerated the tail"
    assert_includes api.turn_windows, { "before_position" => Rho::Extensions::Ops::TURN_POSITION_CEILING, "limit" => 1 },
      "the tail is the one newest row"
  end

  # REGENERATE refuses a non-tail turn with the door's own word.
  def test_regenerate_refuses_a_non_tail_turn_branch_required
    api = NexusDoubles::FakeAgentApi.new(turns: [turn_row("t0", 0), turn_row("t1", 1)],
      variants: variant_deck("t0", { "status" => "untouched" }))
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/conversations/regenerate", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t0" })

    assert_equal "409", response.code, response.body
    assert_equal "branch_required", JSON.parse(response.body).dig("error", "code")
    assert_empty api.regenerations, "the door was never called"
  end

  # REGENERATE on the tail, its world untouched: straight to the door.
  def test_regenerate_of_an_untouched_tail_calls_the_door
    api = NexusDoubles::FakeAgentApi.new(turns: [turn_row("t0", 0)],
      variants: variant_deck("t0", { "status" => "untouched" }))
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/conversations/regenerate", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t0" })

    assert_equal "200", response.code, response.body
    document = JSON.parse(response.body).fetch("regenerate")
    assert_equal "untouched", document.dig("world", "status")
    assert_equal 1, api.regenerations.length, "the door regenerated the tail"
    assert_empty api.loop_creates, "an untouched world restores nothing first"
  end

  # REGENERATE on a tail whose loop WROTE the world: the SDK's restore
  # half (`ConversationContext#restore_world`, the one composition — rho
  # keeps no copy) runs on the conversation's bound runner FIRST, under the
  # rules re-addressed to the seed's origin, then the door.
  def test_regenerate_restores_the_world_through_the_sdk_before_the_door
    api = NexusDoubles::FakeAgentApi.new(turns: [turn_row("t0", 0)], variants: variant_deck("t0", TOUCHED_WORLD),
      task_detail: WORLD_RESTORE_DETAIL)
    api.bind_runner("c-1", REWIND_RUNNER)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/conversations/regenerate", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t0" })

    assert_equal "200", response.code, response.body
    world = JSON.parse(response.body).dig("regenerate", "world")
    assert_equal "restored", world.fetch("status")
    assert_equal "H1", world.fetch("checkpoint")
    assert_equal "H3", world.fetch("undo"), "the undo rides the restore task's metadata"
    authored = api.loop_creates.fetch(0).fetch("agent_loop")
    assert_equal "world_restore", authored.dig("steps", 0, "tool", "name")
    assert_equal({ "checkpoint" => "H1", "store" => "S1" }, authored.dig("steps", 0, "tool", "input"))
    assert(authored.fetch("approval_rules").all? { |rule| rule.fetch("origin") == "author" },
      "the restore's rules are re-addressed to the seed's origin")
    assert_equal 1, api.regenerations.length, "the door was called after the restore"
  end

  # ANOTHER runner (or none) holds the tree and no --keep-world: rho's own
  # refusal off the SDK's `unavailable`, the door never called.
  def test_regenerate_refuses_world_unavailable_when_the_binding_is_not_the_claimant
    api = NexusDoubles::FakeAgentApi.new(turns: [turn_row("t0", 0)], variants: variant_deck("t0", TOUCHED_WORLD))
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/conversations/regenerate", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t0" })

    assert_equal "409", response.code, response.body
    assert_equal "world_unavailable", JSON.parse(response.body).dig("error", "code")
    assert_empty api.loop_creates, "no restore of a tree this binding cannot reach"
    assert_empty api.regenerations, "the door was never called"
  end

  # THE DECK AND ONE CANDIDATE'S VIEW STATE: `rho
  # variant` reads a turn's live candidates through the SDK's deck read,
  # and conceals or restores one through `set_variant_view_state` — the
  # kernel's PATCH on the variant, the sole writer of a sample's view state.
  def test_variant_lists_the_deck_and_conceals_one_candidate_through_the_patch_door
    deck = { "turn" => { "public_id" => "t0", "inherited" => false },
             "variants" => [
               { "public_id" => "v-1", "source" => "inference", "status" => "completed", "active" => false,
                 "content_preview" => "first draft" },
               { "public_id" => "v-2", "source" => "inference", "status" => "completed", "active" => true },
             ] }
    api = NexusDoubles::FakeAgentApi.new(variants: deck)
    daemon = member_ready(boot, api)

    listing = request(daemon, :get, "/conversations/variants?public_id=c-1&turn=t0", token: bearer(daemon))
    assert_equal "200", listing.code, listing.body
    body = JSON.parse(listing.body)
    assert_equal %w[v-1 v-2], body.fetch("variants").map { |row| row.fetch("public_id") }
    assert_equal [false, true], body.fetch("variants").map { |row| row.fetch("active") }
    assert_equal({ "public_id" => "t0", "inherited" => false }, body.fetch("turn"))

    response = request(daemon, :post, "/conversations/variant", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t0", "variant" => "v-1", "concealed" => true })
    assert_equal "200", response.code, response.body
    assert_equal "v-1", JSON.parse(response.body).dig("variant", "public_id")
    assert_equal [["v-1", { "variant" => { "concealed" => true } }]], api.variant_updates,
      "the kernel's PATCH carries the one view-state field"

    malformed = request(daemon, :post, "/conversations/variant", token: bearer(daemon),
      body: { "public_id" => "c-1", "turn" => "t0", "variant" => "v-1" })
    assert_equal "400", malformed.code, "concealed is the one field, and it is required"
  end

  # THE REPLAY'S SPINE: `GET /conversations/
  # turns` pages the kernel's position window (`TurnsController::MAX_LIMIT`
  # rows a read) to the END under a cap, and answers per turn the fields
  # the replay reads — the id, the position, the kind, the role, the
  # status, the origin, the active variant's content, loop and source,
  # and on a reply turn its `prompt_text` (the words that opened it; absent by compaction on a message turn) — with the page's own bounds: the last position (the next
  # read's `after_position`) and whether more stands past it.
  # `after_position` and `limit` ride the query as typed.
  def replay_turn(position, role: "user", loop: nil, content: "words #{position}", prompt: nil)
    variant = { "public_id" => "v#{position}", "source" => loop ? "agent_loop" : "manual", "status" => "completed",
                "content" => content, "content_preview" => content, "prompt_text" => prompt,
                "agent_loop_public_id" => loop }.compact
    turn_row("t#{position}", position).merge("role" => role, "kind" => role == "user" ? "message" : "direct_reply",
      "origin" => "person", "active_variant" => variant)
  end

  def test_the_turns_route_pages_the_kernels_window_to_the_end_and_answers_the_replays_fields
    rows = (0...(Rho::Extensions::Ops::TURN_PAGE * 2 + 5)).map do |position|
      if position.odd?
        replay_turn(position, role: "assistant", loop: "al-#{position}", prompt: "asked #{position}")
      else
        replay_turn(position)
      end
    end
    api = NexusDoubles::FakeAgentApi.new(turns: rows)
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/conversations/turns?public_id=c-1", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    document = JSON.parse(response.body)
    turns = document.fetch("turns")
    assert_equal rows.length, turns.length, "paged to the end"
    assert_equal({ "after_position" => rows.length - 1, "has_more" => false }, document.fetch("pagination"))
    assert_equal [nil, (Rho::Extensions::Ops::TURN_PAGE - 1).to_s, (Rho::Extensions::Ops::TURN_PAGE * 2 - 1).to_s],
      api.turn_windows.map { |window| window["after_position"]&.to_s }, "three windows, each after the last row read"
    assert_equal({ "public_id" => "t1", "position" => 1, "kind" => "direct_reply", "role" => "assistant",
                   "callback_sources" => [],
                   "status" => "completed", "origin" => "person", "inherited" => false, "created_at" => "2026-09-15T00:00:00Z",
                   "answering_user_public_id" => "0199-user",
                   "active_variant" => { "public_id" => "v1", "content_preview" => "words 1",
                                         "content" => "words 1", "prompt_text" => "asked 1", "agent_loop_public_id" => "al-1",
                                         "source" => "agent_loop", "memory_context" => nil } },
      turns.fetch(1), "a reply turn carries the words that opened it")
    assert_equal({ "public_id" => "v0", "content_preview" => "words 0", "content" => "words 0", "source" => "manual", "memory_context" => nil },
      turns.fetch(0).fetch("active_variant"),
      "no loop behind a person's words, no seed either: each key is absent, never null")

    api.turn_windows.clear
    response = request(daemon, :get, "/conversations/turns?public_id=c-1&after_position=3&limit=5", token: bearer(daemon))
    document = JSON.parse(response.body)
    assert_equal (4..8).to_a, document.fetch("turns").map { |turn| turn.fetch("position") }
    assert_equal({ "after_position" => 8, "has_more" => true }, document.fetch("pagination"))
    assert_equal [["3", "5"]], api.turn_windows.map { |window| [window["after_position"].to_s, window["limit"].to_s] },
      "a limit under the kernel's is one window of that size"

    assert_equal "400", request(daemon, :get, "/conversations/turns", token: bearer(daemon)).code
    assert_equal "400", request(daemon, :get, "/conversations/turns?public_id=c-1&limit=0", token: bearer(daemon)).code
  end

  def test_history_keeps_inherited_and_local_turns_distinguishable_in_every_window
    rows = [replay_turn(0, role: "assistant", loop: "parent-loop").merge("inherited" => true),
            replay_turn(1, role: "assistant", loop: "side-loop")]
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(turns: rows))

    ["", "&latest=1", "&before_position=2"].each do |window|
      response = request(daemon, :get, "/conversations/turns?public_id=c-1-side#{window}", token: bearer(daemon))
      assert_equal "200", response.code, response.body
      document = JSON.parse(response.body)
      assert_equal [[0, true], [1, false]],
        document.fetch("turns").map { |turn| [turn.fetch("position"), turn.fetch("inherited")] },
        "history keeps both rows and their provenance; the delivery consumer decides which answers are new"
      assert_equal 1, document.fetch("pagination").fetch("after_position"), "the cursor includes inherited history"
    end
  end

  # AN EMPTY PAGE SAYS NOTHING MORE STANDS: a conversation with no turns,
  # and a window past its last turn, answer no rows, no `after_position`
  # and `has_more` false. `rho turns` prints its next-window verb and the
  # ACP replay reads on from `after_position` whenever `has_more` is true,
  # so an empty page that said true would name a window with no position.
  def test_the_turns_route_answers_an_empty_page_with_nothing_past_it
    empty = { "turns" => [], "pagination" => { "after_position" => nil, "has_more" => false } }
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(turns: []))
    assert_equal empty,
      JSON.parse(request(daemon, :get, "/conversations/turns?public_id=c-1", token: bearer(daemon)).body)

    api = NexusDoubles::FakeAgentApi.new(turns: (0..2).map { |position| replay_turn(position) })
    three = member_ready(boot(root: File.join(@root, "three")), api)
    %w[after_position=2 after_position=2&limit=1].each do |window|
      response = request(three, :get, "/conversations/turns?public_id=c-1&#{window}", token: bearer(three))
      assert_equal "200", response.code, response.body
      assert_equal empty, JSON.parse(response.body), window
    end
  end

  def test_history_carries_the_speaker_model_and_attachment_descriptors
    speaker = NexusDoubles.speaker_row("human-1")
    model = { "provider_id" => "dev", "model_ref" => "mock-text" }
    attachment = { "public_id" => "upload-1", "filename" => "diagram.png", "content_type" => "image/png", "byte_size" => 42 }
    row = replay_turn(0, role: "assistant", loop: "al-1", prompt: "Read this diagram").merge("speaker" => speaker)
    row.fetch("active_variant").merge!("model" => model, "attachments" => [attachment])
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(turns: [row]))

    response = request(daemon, :get, "/conversations/turns?public_id=c-1", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    turn = JSON.parse(response.body).fetch("turns").fetch(0)
    assert_equal speaker, turn.fetch("speaker")
    assert_equal model, turn.dig("active_variant", "model")
    assert_equal [attachment], turn.dig("active_variant", "attachments")
    assert_equal "v0", turn.dig("active_variant", "public_id")
  end

  def test_latest_history_reads_the_tail_and_pages_older_without_losing_the_order
    api = NexusDoubles::FakeAgentApi.new(turns: (0...87).map { |position| replay_turn(position) })
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/conversations/turns?public_id=c-1&latest=1&limit=40", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    document = JSON.parse(response.body)
    assert_equal (47...87).to_a, document.fetch("turns").map { |turn| turn.fetch("position") }
    assert_equal({ "before_position" => 47, "after_position" => 86, "has_older" => true }, document.fetch("pagination"))
    assert_equal [{ "before_position" => Rho::Extensions::Ops::TURN_POSITION_CEILING, "limit" => 40 }], api.turn_windows

    [[47, (7...47).to_a, true], [7, (0...7).to_a, false], [0, [], false]].each do |before, positions, older|
      response = request(daemon, :get, "/conversations/turns?public_id=c-1&before_position=#{before}&limit=40", token: bearer(daemon))
      assert_equal "200", response.code, response.body
      page = JSON.parse(response.body)
      assert_equal positions, page.fetch("turns").map { |turn| turn.fetch("position") }
      assert_equal({ "before_position" => positions.first, "after_position" => positions.last, "has_older" => older }, page.fetch("pagination"))
    end
  end

  def test_latest_empty_history_and_default_page_size
    empty = member_ready(boot, NexusDoubles::FakeAgentApi.new(turns: []))
    response = request(empty, :get, "/conversations/turns?public_id=c-1&latest=1", token: bearer(empty))
    assert_equal({ "turns" => [], "pagination" => { "before_position" => nil, "after_position" => nil, "has_older" => false } },
      JSON.parse(response.body))

    rows = (0..Rho::Extensions::Ops::TURN_PAGE).map { |position| replay_turn(position) }
    api = NexusDoubles::FakeAgentApi.new(turns: rows)
    daemon = member_ready(boot(root: File.join(@root, "pages")), api)
    document = JSON.parse(request(daemon, :get, "/conversations/turns?public_id=c-1&latest=1", token: bearer(daemon)).body)
    assert_equal (1..Rho::Extensions::Ops::TURN_PAGE).to_a, document.fetch("turns").map { |turn| turn.fetch("position") }
    assert_equal Rho::Extensions::Ops::TURN_PAGE, api.turn_windows.fetch(0).fetch("limit")
  end

  def test_history_window_directions_are_exclusive_and_positions_are_typed
    api = NexusDoubles::FakeAgentApi.new(turns: [])
    daemon = member_ready(boot, api)
    %w[before_position=no after_position=no before_position=4&after_position=1
       latest=1&after_position=0 latest=1&before_position=4].each do |query|
      response = request(daemon, :get, "/conversations/turns?public_id=c-1&#{query}", token: bearer(daemon))
      assert_equal "400", response.code, "#{query}: #{response.body}"
    end
    assert_empty api.turn_windows
  end

  # THE CAP: a conversation deeper than `TURNS_PAGE_CAP` windows answers
  # what the cap allowed and `has_more`, never an unbounded scan.
  def test_the_turns_route_stops_at_its_cap_and_says_more_stands_past_it
    depth = Rho::Extensions::Ops::TURN_PAGE * (Rho::Extensions::Ops::LoopRoutes::TURNS_PAGE_CAP + 1)
    api = NexusDoubles::FakeAgentApi.new(turns: (0...depth).map { |position| replay_turn(position) })
    daemon = member_ready(boot, api)

    document = JSON.parse(request(daemon, :get, "/conversations/turns?public_id=c-1", token: bearer(daemon)).body)

    capped = Rho::Extensions::Ops::TURN_PAGE * Rho::Extensions::Ops::LoopRoutes::TURNS_PAGE_CAP
    assert_equal capped, document.fetch("turns").length
    assert_equal({ "after_position" => capped - 1, "has_more" => true }, document.fetch("pagination"))
    assert_equal Rho::Extensions::Ops::LoopRoutes::TURNS_PAGE_CAP, api.turn_windows.length
  end
end
