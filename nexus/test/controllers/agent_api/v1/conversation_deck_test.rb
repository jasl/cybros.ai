require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationDeckTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  # THE PERSON'S WORDS ON THE WIRE: a `say` is ONE `direct_reply` turn, so the timeline names what
  # opened it — `prompt_text`, the seed's words — beside the reply it produces; the turn carries it
  # from materialization, before any `content` exists, and the SSE snapshot renders the same block.
  test "a reply turn's variant carries prompt_text, the words that opened it, from materialization" do
    conversation = create_conversation!
    post conversation_inputs_path(conversation), headers: auth("p-1"), as: :json,
      params: { input: { kind: "direct_reply", text: "what is next?", model: { model: "dev/mock-text" } } }
    assert_response :accepted
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob

    get conversation_turns_path(conversation), headers: auth
    turn = response.parsed_body.fetch("turns").sole
    assert_equal %w[direct_reply assistant], [turn.fetch("kind"), turn.fetch("role")]
    variant = turn.fetch("active_variant")
    assert_equal "what is next?", variant.fetch("prompt_text"), "the seed's own words"
    assert_not variant.key?("content"), "nothing answered yet: content is absent, the prompt is not"
    assert_equal variant.fetch("prompt_text"),
      AgentAPI::ConversationPresenter.turn_snapshot(conversation.conversation_turns.sole)
        .dig(:active_variant, :prompt_text), "the snapshot renders the one block"
  end

  # A loop-backed variant exposes its loop, round summaries and derived runner_effects facts. Regeneration
  # returns 202 with a new candidate and a new loop; the kernel does not infer filesystem
  # restoration from a prior runner_effects capture.
  test "a loop-backed turn's variant carries the loop's id, rounds and runner_effects, and regenerate births a loop" do
    conversation = create_conversation!
    post conversation_inputs_path(conversation), headers: auth("i-before"), as: :json,
      params: { input: { text: "the question" } }
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    seam = create_run_backed_turn(conversation: conversation.reload, acting_user: @human)
    appended = grow(seam.agent_run, model("r1", "prompt" => "go"))
    assert_predicate appended, :applied?
    runner_tool_row(seam.agent_run, "r2t0", claimed_by: "01900000-0000-7000-8000-0000000000e1",
      metadata: { "checkpoint" => { "hash" => "h1", "store" => "s1" } })
    AgentRuns::Transition.agent_run(seam.agent_run, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call

    get conversation_turns_path(conversation), headers: auth
    run_backed = response.parsed_body.fetch("turns").last.fetch("active_variant")
    assert_equal "run", run_backed.fetch("source")
    assert_equal seam.agent_run.public_id, run_backed.fetch("run_public_id")
    round = run_backed.fetch("rounds").sole
    assert_equal "r1", round.fetch("task_key")
    assert_equal "waiting", round.fetch("status")
    %w[continue mainline calls branches].each do |word|
      assert_not round.key?(word), "never a DAG word on a turn: #{word}"
    end
    assert_equal(
      { "status" => "touched", "runners" => [{ "run_public_id" => seam.agent_run.public_id, "task_key" => "r2t0",
        "runner_executor_public_id" => "01900000-0000-7000-8000-0000000000e1", "checkpoint" => { "hash" => "h1", "store" => "s1" } }] },
      run_backed.fetch("runner_effects"), "the fact: the claimant and the runner's record verbatim"
    )

    get "#{conversation_turns_path(conversation)}/#{seam.turn.public_id}/variants", headers: auth
    deck = response.parsed_body.fetch("variants").sole
    assert_equal seam.agent_run.public_id, deck.fetch("run_public_id")
    assert_equal ["r1"], deck.fetch("rounds").map { |row| row.fetch("task_key") }
    assert_equal run_backed.fetch("runner_effects"), deck.fetch("runner_effects"), "the deck reads the same fact"

    origin_nodes = seam.agent_run.agent_run_tasks.order(:id).pluck(:id, :status)
    post "#{conversation_turns_path(conversation)}/#{seam.turn.public_id}/regeneration",
      headers: auth(SecureRandom.uuid), as: :json, params: { regeneration: { model: { model: "dev/mock-text" } } }
    assert_response :accepted
    sibling = response.parsed_body.fetch("variant")
    assert_equal "run", sibling.fetch("source")
    assert_equal false, sibling.fetch("active")
    new_loop = AgentRun.find_by!(public_id: sibling.fetch("run_public_id"))
    assert_not_equal seam.agent_run.id, new_loop.id, "its OWN loop, the feed's correlation key on the 202"
    assert_equal [{ "task_key" => "r1", "status" => "waiting", "visibility" => "visible" }], sibling.fetch("rounds"),
      "the rebuilt seed round, queued for the scheduler, is the new loop's one visible round"
    assert_equal({ "status" => "untouched", "runners" => [] }, sibling.fetch("runner_effects"), "nothing has run behind the new candidate")
    assert_equal "running", response.parsed_body.dig("turn", "status")
    assert_equal origin_nodes, seam.agent_run.reload.agent_run_tasks.order(:id).pluck(:id, :status),
      "the origin's loop is untouched"
    assert_equal "completed", seam.agent_run.status

    get "#{conversation_turns_path(conversation)}/#{seam.turn.public_id}/variants", headers: auth
    deck = response.parsed_body.fetch("variants")
    assert_equal 2, deck.length, "a deck of two"
    assert_equal [seam.agent_run.public_id, new_loop.public_id], deck.map { |row| row.fetch("run_public_id") }
    assert_equal [true, false], deck.map { |row| row.fetch("active") }, "the old candidate keeps rendering"

    # The new loop lands as any loop-backed reply does; the turn returns.
    AgentRuns::Transition.agent_run(new_loop, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call
    post conversation_inputs_path(conversation), headers: auth("i-after"), as: :json,
      params: { input: { text: "and then" } }
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    get conversation_turns_path(conversation), headers: auth
    direct = response.parsed_body.fetch("turns").last.fetch("active_variant")
    assert_not direct.key?("run_public_id")
    assert_not direct.key?("rounds"), "a turn with no loop behind it carries neither key"
    assert_not direct.key?("runner_effects"), "nor a runner_effects"
  end

  # EVERY DECK DOOR, THE ONE BLOCK: a reply turn's seed — `prompt_text`, the person's words — rides
  # the deck listing, the regeneration 202, the swipe's answer, the view-state answer and the edit's
  # answer exactly as it rides the turns page, read by presence off the candidate's OWN `prompt`
  # body: `keep_prompt` writes the original's, Regenerate and Edit clone the origin's onto the
  # sibling (`carry_prompt` on both). A message turn's content IS the person's words: its deck and
  # its edit carry none.
  test "every deck door carries a reply turn's prompt_text as the turns page does; a message turn's carries none" do
    conversation = create_conversation!
    post conversation_inputs_path(conversation), headers: auth("d-1"), as: :json,
      params: { input: { kind: "direct_reply", text: "what is next?", model: { model: "dev/mock-text" } } }
    assert_response :accepted
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    turn = conversation.conversation_turns.sole
    get "#{conversation_turns_path(conversation)}/#{turn.public_id}/variants", headers: auth
    row = response.parsed_body.fetch("variants").sole
    assert_equal "what is next?", row.fetch("prompt_text"), "the deck reads the seed the drain kept, before any content"
    assert_not row.key?("content")

    # A message below the seam: the regeneration re-assembles strictly
    # below the turn (the seam names no model trio to clone under).
    lane = create_conversation!(title: "seam")
    post conversation_inputs_path(lane), headers: auth("d-seam"), as: :json, params: { input: { text: "the question" } }
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    seam = create_run_backed_turn(conversation: lane.reload, acting_user: @human)
    ContentBodies::Replace.call(owner: seam.variant, role: "prompt", entries: [{ "text" => "and then?" }],
      readable_text: "and then?", seal: true)
    grow!(seam.agent_run, model("r1", "prompt" => "go"))
    AgentRuns::Transition.agent_run(seam.agent_run, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call
    turn_path = "#{conversation_turns_path(lane)}/#{seam.turn.public_id}"

    post "#{turn_path}/regeneration", headers: auth(SecureRandom.uuid), as: :json,
      params: { regeneration: { model: { model: "dev/mock-text" } } }
    assert_response :accepted
    sibling = response.parsed_body.fetch("variant")
    assert_equal "and then?", sibling.fetch("prompt_text"),
      "the 202 names the seed the service cloned onto the newborn candidate (Regenerate#carry_prompt)"
    assert_not sibling.key?("content"), "and no content yet"

    new_loop = AgentRun.find_by!(public_id: sibling.fetch("run_public_id"))
    AgentRuns::Transition.agent_run(new_loop, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call
    get "#{turn_path}/variants", headers: auth
    deck = response.parsed_body.fetch("variants")
    assert_equal ["and then?", "and then?"], deck.map { |candidate| candidate.fetch("prompt_text") },
      "every candidate names the turn's one seed"
    assert_equal [false, true], deck.map { |candidate| candidate.fetch("active") },
      "the completed sample became the rendered one"

    post "#{turn_path}/variants/#{seam.variant.public_id}/activation", headers: auth, as: :json
    assert_response :success
    assert_equal "and then?", response.parsed_body.dig("variant", "prompt_text"), "the swipe's answer"

    patch "#{turn_path}/variants/#{sibling.fetch("public_id")}", headers: auth, as: :json,
      params: { variant: { concealed: true } }
    assert_response :success
    assert_equal "and then?", response.parsed_body.dig("variant", "prompt_text"), "the view-state answer"

    post "#{turn_path}/edit", headers: auth, as: :json, params: { edit: { text: "my own answer" } }
    assert_response :success
    edited = response.parsed_body.fetch("variant")
    assert_equal "and then?", edited.fetch("prompt_text"), "the edit sibling carries the origin's seed (Edit#carry_prompt)"
    assert_equal "my own answer", edited.fetch("content")

    plain = create_conversation!(title: "plain")
    post conversation_inputs_path(plain), headers: auth("d-2"), as: :json, params: { input: { text: "hello there" } }
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    message = plain.conversation_turns.sole
    post "#{conversation_turns_path(plain)}/#{message.public_id}/edit", headers: auth, as: :json,
      params: { edit: { text: "hello again" } }
    assert_response :success
    assert_not response.parsed_body.fetch("variant").key?("prompt_text"),
      "a message turn's edit answer carries no prompt_text: its content IS the person's words"
    get "#{conversation_turns_path(plain)}/#{message.public_id}/variants", headers: auth
    assert response.parsed_body.fetch("variants").none? { |candidate| candidate.key?("prompt_text") },
      "nor does its deck"
  end

  # A hold-settled loop is adjudicable: regenerating beside it would run two live loops behind one
  # turn. Refused, 409.
  test "regenerate refuses run_needs_attention while the origin's loop awaits adjudication" do
    conversation = create_conversation!
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    grow!(seam.agent_run, model("r1", "prompt" => "go"))
    AgentRuns::Transition.agent_run(seam.agent_run, status: "needs_attention", attention_reason: "halt_failure")
    Conversations::Turns::Converge.call
    assert_equal "failed", seam.turn.reload.status

    post "#{conversation_turns_path(conversation)}/#{seam.turn.public_id}/regeneration",
      headers: auth(SecureRandom.uuid), as: :json, params: { regeneration: { model: { model: "dev/mock-text" } } }
    assert_response :conflict
    assert_equal "run_needs_attention", response.parsed_body.dig("error", "code")
    assert_equal 1, seam.turn.conversation_turn_variants.count
  end

  # THE FORK ANSWER'S WORLD: `{conversation, runner_effects}` — the fact for the fork point by the physical
  # rule, computed after the fork and carried on the receipt, so a replay answers the same value.
  test "fork answers runner_effects for the fork point, the same on replay; a side fork's point has nothing above it" do
    conversation = create_conversation!
    post conversation_inputs_path(conversation), headers: auth("i-w"), as: :json,
      params: { input: { text: "the boundary message" } }
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    message = conversation.conversation_turns.sole
    seam = create_run_backed_turn(conversation: conversation.reload, acting_user: @human)
    runner_tool_row(seam.agent_run, "r1t0", claimed_by: "01900000-0000-7000-8000-0000000000e1",
      metadata: { "checkpoint" => { "hash" => "h1", "store" => "s1" } })
    AgentRuns::Transition.agent_run(seam.agent_run, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call

    post conversation_forks_path(conversation), headers: auth("f-w"), as: :json,
      params: { fork: { turn_public_id: message.public_id } }
    assert_response :created
    assert_equal "false", response.headers["Idempotency-Replayed"]
    runner_effects = { "status" => "touched", "runners" => [{ "run_public_id" => seam.agent_run.public_id, "task_key" => "r1t0",
      "runner_executor_public_id" => "01900000-0000-7000-8000-0000000000e1", "checkpoint" => { "hash" => "h1", "store" => "s1" } }] }
    assert_equal runner_effects, response.parsed_body.fetch("runner_effects"), "the first write above the message"
    child_public_id = response.parsed_body.dig("conversation", "public_id")

    post conversation_forks_path(conversation), headers: auth("f-w"), as: :json,
      params: { fork: { turn_public_id: message.public_id } }
    assert_response :created
    assert_equal "true", response.headers["Idempotency-Replayed"]
    assert_equal child_public_id, response.parsed_body.dig("conversation", "public_id")
    assert_equal runner_effects, response.parsed_body.fetch("runner_effects"), "a replay answers the same runner_effects off the receipt"

    post conversation_forks_path(conversation), headers: auth("f-w-tail"), as: :json,
      params: { fork: { turn_public_id: seam.turn.public_id } }
    assert_response :created
    assert_equal({ "status" => "untouched", "runners" => [] }, response.parsed_body.fetch("runner_effects"), "the tail: N's own writes stand")

    post conversation_forks_path(conversation), headers: auth("f-w-side"), as: :json,
      params: { fork: { side: true } }
    assert_response :created
    assert_equal({ "status" => "untouched", "runners" => [] }, response.parsed_body.fetch("runner_effects"))
  end

  test "fork answers with the child and narrates in the source's stream" do
    conversation = create_conversation!
    post conversation_inputs_path(conversation), headers: auth("i-3"), as: :json,
      params: { input: { text: "the boundary message" } }
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    turn_public_id = conversation.conversation_turns.sole.public_id

    post conversation_forks_path(conversation), headers: auth("f-1"), as: :json,
      params: { fork: { turn_public_id: turn_public_id } }

    assert_response :created
    child_public_id = response.parsed_body.dig("conversation", "public_id")
    assert_equal turn_public_id,
      response.parsed_body.dig("conversation", "forked_from_turn_public_id")

    get conversation_events_path(conversation), headers: auth
    types = response.parsed_body.fetch("events").map { |e| e["type"] }
    assert_includes types, "fork_created"
    watermark = response.parsed_body.dig("pagination", "watermark")
    assert_operator watermark, :>, 0

    child = Conversation.find_by!(public_id: child_public_id)
    get conversation_events_path(child), headers: auth
    assert_equal 0, response.parsed_body.dig("pagination", "watermark"),
      "a child starts an empty stream"
  end

  # The side fork: no turn named — the fork point is the parent's newest settled turn; a turn named
  # beside `side` is not read; a plain fork still owes its turn.
  test "a side fork over HTTP names no turn; the working list hides it; DELETE reaps it at once" do
    conversation = create_conversation!(title: "main")
    post conversation_inputs_path(conversation), headers: auth("i-side"), as: :json,
      params: { input: { text: "the settled message" } }
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    settled = conversation.conversation_turns.sole

    post conversation_forks_path(conversation), headers: auth("f-side"), as: :json,
      params: { fork: { side: true } }
    assert_response :created
    side = Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))
    assert_predicate side, :side?
    assert_equal true, response.parsed_body.dig("conversation", "side"), "the wire says side"
    assert_equal settled.public_id, response.parsed_body.dig("conversation", "forked_from_turn_public_id")
    assert_equal 0, side.conversation_turns.count

    post conversation_forks_path(conversation), headers: auth("f-side-2"), as: :json,
      params: { fork: { side: true, turn_public_id: SecureRandom.uuid_v7 } }
    assert_response :created, "a named turn beside side is not read"

    post conversation_forks_path(conversation), headers: auth("f-plain"), as: :json,
      params: { fork: { title: "no turn" } }
    assert_response :bad_request, "a plain fork owes its turn"
    assert_equal 3, Conversation.count

    get conversations_path, headers: auth
    assert_equal ["main"], response.parsed_body.fetch("conversations").map { |c| c["title"] },
      "the working list hides sides"
    assert_equal [false], response.parsed_body.fetch("conversations").map { |c| c["side"] }
    get "#{conversations_path}?side=1", headers: auth
    assert_equal 2, response.parsed_body.fetch("conversations").length, "?side=1 lists sides only"
    assert_equal [true, true], response.parsed_body.fetch("conversations").map { |c| c["side"] }
    assert response.parsed_body.fetch("conversations").none? { |c| c["public_id"] == conversation.public_id }

    delete conversation_path(side), headers: auth
    assert_response :no_content
    assert_not Conversation.exists?(side.id), "tombstone AND reap in one call"
    get conversation_path(side), headers: auth
    assert_response :not_found
  end

  test "the undo verb's causes all answer 409 on the wire" do
    conversation = create_conversation!
    %w[first second].each do |text|
      post conversation_inputs_path(conversation), headers: auth("w-#{text}"), as: :json,
        params: { input: { text: text } }
    end
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    first_turn, second_turn = conversation.conversation_turns.order(:position).to_a

    delete "#{conversation_turns_path(conversation)}/#{first_turn.public_id}", headers: auth
    assert_response :conflict
    assert_equal "apex_only", response.parsed_body.dig("error", "code")

    child = Conversation.create!(workspace: @workspace, creating_user: @human)
    ConversationAncestry.create!(
      account: @account, conversation: child,
      ancestor_conversation: conversation, depth: 1, boundary_position: 1
    )
    delete "#{conversation_turns_path(conversation)}/#{second_turn.public_id}", headers: auth
    assert_response :conflict
    assert_equal "descendant_pinned", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), child.public_id,
      "the answer names the pinning fork"
  end

  test "the inherited deck reads the child's own view, never the shared row" do
    parent = create_conversation!
    %w[shared-content boundary].each_with_index do |text, index|
      post conversation_inputs_path(parent), headers: auth("d-#{index}"), as: :json,
        params: { input: { text: text } }
    end
    perform_enqueued_jobs only: Conversations::Inputs::DrainJob
    turn, boundary = parent.conversation_turns.order(:position).to_a
    post conversation_forks_path(parent), headers: auth("d-fork"), as: :json,
      params: { fork: { turn_public_id: boundary.public_id } }
    child = Conversation.find_by!(
      public_id: response.parsed_body.dig("conversation", "public_id")
    )

    deck_path = "#{conversation_path(child)}/turns/#{turn.public_id}/variants"
    get deck_path, headers: auth
    assert_response :success, "the child reads the inherited deck through its reach"

    patch "#{conversation_path(child)}/turns/#{turn.public_id}", headers: auth, as: :json,
      params: { turn: { concealed: true } }
    assert_response :success
    get deck_path, headers: auth
    assert_response :not_found, "the child's own override conceals ITS deck read"

    get "#{conversation_path(parent)}/turns/#{turn.public_id}/variants", headers: auth
    assert_response :success,
      "the child's override touches nobody else — the parent's deck still reads"
  end

  # THE DEBUG DOOR: the sealed request as sent — exactly the sealed entries and the request_options,
  # derived from the body, never re-assembled; a loop-backed variant answers its first round's; a
  # variant with none is `request_not_sealed`; browse standing reads it.
  test "GET variants/{id}/request answers exactly the sealed entries and request_options" do
    conversation = create_conversation!
    PromptDocuments::Write.call(anchor: { workspace: @workspace }, slot: "character", content: "The room.")
    post conversation_inputs_path(conversation), headers: auth("rq-1"), as: :json,
      params: { input: { kind: "direct_reply", text: "what is up", model: { model: "dev/mock-text" },
                         configuration: { temperature: 0.2 } } }
    assert_response :accepted
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    turn = conversation.conversation_turns.order(:position).last
    variant = turn.active_variant
    invocation = variant.model_invocation

    get request_path(conversation, turn, variant), headers: auth
    assert_response :success
    body = response.parsed_body
    assert_equal %w[request], body.keys
    assert_equal %w[entries request_options], body.fetch("request").keys, "two keys, nothing derived"
    assert_equal ModelRequests::InputSource.accepted_entry_payloads(invocation).as_json,
      body.dig("request", "entries")
    assert_equal invocation.request_options, body.dig("request", "request_options")
    assert_equal 0.2, body.dig("request", "request_options", "temperature")
    assert_not body.dig("request", "request_options").key?("instructions")
    assert_equal %w[system user], body.dig("request", "entries").map { |entry| entry["role"] }
    assert_equal "The room.", body.dig("request", "entries", 0, "parts", 0, "text")

    agent = users(:agent)
    connection = connect_agent_session(steward: users(:owner), agent_identifier: agent.agent_identifier)
    Workspace.where(id: @workspace.id).update_all(agent_identifier: "some-other-program")
    get request_path(conversation, turn, variant), headers: { "Authorization" => "Bearer #{connection.access_secret}" }
    assert_response :success, "a browse-only caller reads the workspace's own bytes"
  end

  test "a loop-backed variant's request is its first round's, and 404 before any round sealed" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    get request_path(conversation, seam.turn, seam.variant), headers: auth
    assert_response :not_found
    assert_equal "request_not_sealed", response.parsed_body.dig("error", "code")

    agent = users(:agent)
    Users::DeclareConfiguration.call(user: agent,
      tool_definitions: [{ "type" => "function", "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } }],
      approval_mode: "bypass", approval_rules: nil, prompt_mechanism: nil, prompt_template: nil, compaction_policy: nil
    )
    lane = Conversation.create!(workspace: @workspace, creating_user: agent)
    post conversation_inputs_path(lane), headers: auth("rq-2"), as: :json,
      params: { input: { kind: "direct_reply", text: "go", model: { model: "dev/mock-text" } } }
    assert_response :accepted
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: lane.id)
    turn = lane.conversation_turns.order(:position).last
    agent_run = turn.active_variant.agent_run
    assert_equal "default", agent_run.prompt_mechanism
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    r1 = agent_run.agent_run_tasks.find_by!(node_key: "r1")

    get request_path(lane, turn, turn.active_variant), headers: auth
    assert_response :success
    assert_equal ModelRequests::InputSource.accepted_entry_payloads(r1.selected_model_invocation).as_json,
      response.parsed_body.dig("request", "entries")
    assert_equal ["read_file"], response.parsed_body.dig("request", "request_options", "tools").map { |t| t.dig("function", "name") }
  end
end
