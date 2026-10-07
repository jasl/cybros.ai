require_relative "conversation_turn_test"

class ConversationTurnTest
  # THE DECK, through a deployment: asking again ADDS a sample beside the
  # original rather than replacing it, and the swipe chooses which one the
  # timeline renders.
  def test_a_regeneration_joins_the_deck_and_the_swipe_chooses
    chat = @conversations.conversation(
      @conversations.create(idempotency_key: SecureRandom.uuid).public_id
    )
    asked = "!mock -- first"
    accepted = chat.inputs.create(
      kind: "direct_reply", model: MODEL, text: asked,
      idempotency_key: SecureRandom.uuid
    )
    original = await_settled_reply(chat).items.last
    assert_equal "Mock: first", original.text
    assert_equal original, chat.turns.fetch(original.public_id), "a point read uses the timeline projection"
    materialization = chat.inputs.materialization(accepted.public_id)
    assert_equal original.public_id, materialization.turn_public_id
    assert_equal original.active_variant.public_id, materialization.variant_public_id

    regeneration_key = SecureRandom.uuid
    regenerated = chat.turns.regenerate(original.public_id, idempotency_key: regeneration_key, model: MODEL)
    assert_equal "running", regenerated.turn_status
    refute_predicate regenerated.variant, :active?,
      "the original keeps being rendered while the new sample runs"

    deck = await_full_deck(chat, original.public_id)
    assert_equal 2, deck.length, "asking again ADDS — nothing in this plane replaces"
    # THE WORDS THAT OPENED THE TURN RIDE EVERY CANDIDATE: the original's
    # seed is the person's input (ApplyNext#keep_prompt) and the regeneration
    # copies the origin's seed onto the newborn (Regenerate#carry_prompt), so
    # the deck reads the same words on every row, verbatim.
    assert_equal [asked, asked], deck.items.map(&:prompt_text),
      "every candidate names the words the person sent to open the turn"
    refute_equal original.active_variant.public_id, deck.active.public_id,
      "a completed sample becomes what the timeline shows"
    assert_equal materialization, chat.inputs.materialization(accepted.public_id),
      "regeneration never retargets an accepted input's original candidate"

    receipt = chat.turns.regeneration_receipt(idempotency_key: regeneration_key)
    replay = chat.turns.regenerate(original.public_id, idempotency_key: regeneration_key, model: MODEL)
    assert_predicate replay, :replayed?
    assert_equal regenerated.variant.public_id, receipt.variant.public_id
    assert_equal regenerated.variant.public_id, replay.variant.public_id
    assert_equal "running", replay.turn_status, "a replay retains the original acceptance"
    assert_equal 2, chat.turns.variants(original.public_id).length, "a settled retry never adds a sample"
    error = assert_raises(CybrosAgent::Api::Conflict) do
      chat.turns.regenerate(original.public_id, idempotency_key: regeneration_key, configuration: {})
    end
    assert_equal "idempotency_envelope_mismatch", error.code

    # AND NOTHING WAS LOST: the first answer is still in the deck, and the
    # swipe back is what makes that true rather than merely stated.
    first = deck.items.find { |variant| variant.public_id == original.active_variant.public_id }
    refute_nil first, "the previous answer stays a candidate"
    switched = chat.turns.activate(original.public_id, first.public_id)
    assert_equal first.public_id, switched.public_id
    assert_predicate switched, :active?
    assert_equal original.text, chat.turns.list.items.last.text,
      "the swipe is what the timeline renders now"
  end

  def test_a_different_model_regenerates_the_first_turns_question
    chat = @conversations.conversation(
      @conversations.create(idempotency_key: SecureRandom.uuid).public_id
    )
    asked = "!mock -- retain this question"
    chat.inputs.create(kind: "direct_reply", model: MODEL, text: asked, idempotency_key: SecureRandom.uuid)
    original = await_settled_reply(chat).items.last
    assert_equal "Mock: retain this question", original.text

    regenerated = chat.turns.regenerate(original.public_id, idempotency_key: SecureRandom.uuid, model: "dev/mock-text-only")
    deck = await_full_deck(chat, original.public_id)

    assert_equal regenerated.variant.public_id, deck.active.public_id
    assert_equal asked, deck.active.prompt_text
    assert_equal "Mock: retain this question", chat.turns.list.items.last.text
  end

  def test_raw_regeneration_retains_instructions_and_can_reset_generation_parameters
    chat = @conversations.conversation(
      @conversations.create(idempotency_key: SecureRandom.uuid).public_id
    )
    instructions = "Answer using the supplied facts only."
    configuration = { "temperature" => 0.2, "max_output_tokens" => 37 }
    chat.inputs.create(kind: "direct_reply", model: MODEL, context_mode: "raw",
      text: "!mock -- keep the request", instructions: instructions,
      configuration: configuration, idempotency_key: SecureRandom.uuid)
    original = await_settled_reply(chat).items.last
    source = chat.turns.request(original.public_id, original.active_variant.public_id)

    inherited = chat.turns.regenerate(original.public_id, idempotency_key: SecureRandom.uuid)
    deck = await_full_deck(chat, original.public_id)
    assert_equal inherited.variant.public_id, deck.active.public_id
    request = chat.turns.request(original.public_id, inherited.variant.public_id)
    assert_equal source.entries, request.entries
    assert_equal source.request_options, request.request_options
    assert_equal instructions, request.request_options.fetch("instructions")
    assert_equal configuration, request.request_options.slice(*configuration.keys)

    reset = chat.turns.regenerate(original.public_id, idempotency_key: SecureRandom.uuid, configuration: {})
    deck = await_full_deck(chat, original.public_id)
    assert_equal reset.variant.public_id, deck.active.public_id
    request = chat.turns.request(original.public_id, reset.variant.public_id)
    assert_equal source.entries, request.entries
    assert_equal instructions, request.request_options.fetch("instructions")
    assert_equal({ "temperature" => 1.0, "max_output_tokens" => 256 },
      request.request_options.slice(*configuration.keys))
    assert_equal source.request_options,
      chat.turns.request(original.public_id, original.active_variant.public_id).request_options
  end

  def test_raw_messages_survive_regeneration_on_a_different_model
    chat = @conversations.conversation(
      @conversations.create(idempotency_key: SecureRandom.uuid).public_id
    )
    chat.inputs.create(kind: "message", text: "History outside the raw request.",
      idempotency_key: SecureRandom.uuid)
    await("the earlier message") { chat.turns.list.items.length == 1 }
    entries = [
      { "role" => "system", "parts" => [{ "type" => "text", "text" => "Use the supplied conversation." }] },
      { "role" => "user", "parts" => [{ "type" => "text", "text" => "An earlier raw question." }] },
      { "role" => "assistant", "parts" => [{ "type" => "text", "text" => "An earlier raw answer." }] },
      { "role" => "user", "parts" => [{ "type" => "text", "text" => "!mock -- raw request preserved" }] },
    ]
    chat.inputs.create(kind: "direct_reply", model: MODEL, context_mode: "raw",
      entries: entries, idempotency_key: SecureRandom.uuid)
    original = await_settled_reply(chat).items.last
    source = chat.turns.request(original.public_id, original.active_variant.public_id)
    assert_equal entries, source.entries

    regenerated = chat.turns.regenerate(original.public_id, idempotency_key: SecureRandom.uuid, model: "dev/mock-text-only")
    deck = await_full_deck(chat, original.public_id)
    assert_equal regenerated.variant.public_id, deck.active.public_id
    assert_equal entries, chat.turns.request(original.public_id, regenerated.variant.public_id).entries
    assert_equal "Mock: Use the supplied conversation.\nAn earlier raw question.\nAn earlier raw answer.\nraw request preserved",
      chat.turns.list.items.last.text
    assert_equal source.entries,
      chat.turns.request(original.public_id, original.active_variant.public_id).entries
  end

  def test_rho_regeneration_replaces_the_same_turns_followed_task_table
    boot_rho!
    # The first call already has its continuation; two groups leave a later
    # round that the new candidate has not authored while its first call waits.
    calls = ["sleep #{E2E::RhoDaemon::HOLD_SECONDS}", "printf regenerated"].map do |command|
      "bash:#{CGI.escape(JSON.generate("command" => command))}"
    end
    conversation, first_loop = rho_open("!mock tool_call=#{calls.join(",")} -- regenerate this answer")
    chat = steward_conversation(conversation)
    completed = await_rho_loop(first_loop, "completed")
    original = await_settled_reply(chat).items.last
    first = await_follower(conversation, loop: first_loop)
    last_round = completed.tasks.reverse.find { |task| task.kind == "model_task" }.key
    assert_includes first.fetch("tasks").map { |task| task.fetch("task_key") }, last_round,
      "the first candidate completed the round after its tool call"

    regenerated = chat.turns.regenerate(original.public_id, idempotency_key: SecureRandom.uuid, model: MODEL)
    next_loop = regenerated.variant.run_public_id
    refute_equal first_loop, next_loop
    running = await("rho following the regenerated candidate's running tool") do
      row = @daemon.control(:get, "/followers").fetch("followers").find { |candidate| candidate["public_id"] == conversation }
      row if row && row["run_public_id"] == next_loop && row.fetch("tasks").any? do |task|
        task["kind"] == "tool_task" && task["status"] == "dispatched"
      end
    end
    assert_equal original.public_id, running.fetch("turn"), "regeneration reuses the turn"
    current = rho_loops.fetch(next_loop)
    refute_includes current.tasks.map(&:key), last_round, "the new candidate is still waiting for its first tool"
    refute_includes running.fetch("tasks").map { |task| task.fetch("task_key") }, last_round,
      "rho must not report the previous candidate's completed round as part of the new loop: #{running.inspect}"
    assert_empty running.fetch("text"), "the previous candidate's answer is not the new candidate's preview"

    await_rho_loop(next_loop, "completed")
    settled = await_follower(conversation, loop: next_loop)
    assert_equal "completed", settled.fetch("status")
    deck = await_full_deck(chat, original.public_id)
    assert_equal regenerated.variant.public_id, deck.active.public_id
    assert_equal next_loop, deck.active.run_public_id
  end

  def test_regenerated_calls_can_be_approved_or_denied_and_cancellation_keeps_the_last_answer
    boot_rho!
    arguments = CGI.escape(JSON.generate("command" => "printf granted >> approvals.txt"))
    conversation, first_loop = rho_open("!mock tool_call=bash tool_args=#{arguments} -- report the decision", "--approval", "ask")
    chat = steward_conversation(conversation)
    first_call = await_rho_approval(first_loop)
    output, status = @daemon.cli("approve", first_loop, first_call.key)
    assert_predicate status, :success?, output
    await_rho_loop(first_loop, "completed")
    original = await_settled_reply(chat).items.last
    await_follower(conversation, loop: first_loop)

    %w[approve deny].each do |decision|
      regenerated = chat.turns.regenerate(original.public_id, idempotency_key: SecureRandom.uuid, model: MODEL)
      next_loop = regenerated.variant.run_public_id
      call = await_rho_approval(next_loop)
      command = [decision, next_loop, call.key]
      command << "keep the existing file" if decision == "deny"
      output, status = @daemon.cli(*command)
      assert_predicate status, :success?, "a regenerated call must be adjudicable:\n#{output}"
      completed = await_rho_loop(next_loop, "completed")
      decided = completed.tasks.find { |task| task.key == call.key }
      assert_equal decision == "approve" ? "completed" : "failed", decided.status
      assert_equal "approval_denied", decided.error.fetch("key") if decision == "deny"
      deck = await_full_deck(chat, original.public_id)
      assert_equal regenerated.variant.public_id, deck.active.public_id
      assert_includes deck.active.content, "keep the existing file" if decision == "deny"
      await_follower(conversation, loop: next_loop)
    end
    assert_equal "grantedgranted", File.read(File.join(@project, "approvals.txt")),
      "only the original and approved regenerated call ran"

    previous = chat.turns.list.items.last
    canceled = chat.turns.regenerate(original.public_id, idempotency_key: SecureRandom.uuid, model: MODEL)
    canceled_loop = canceled.variant.run_public_id
    await_rho_approval(canceled_loop)
    output, status = @daemon.cli("stop", conversation)
    assert_predicate status, :success?, output
    deck = await("the canceled candidate to settle in the deck") do
      rows = chat.turns.variants(original.public_id)
      rows if rows.items.find { |variant| variant.public_id == canceled.variant.public_id }&.status == "canceled"
    end
    assert_equal previous.active_variant.public_id, deck.active.public_id
    retained = chat.turns.list.items.last
    assert_equal "completed", retained.status
    assert_equal previous.text, retained.text
    assert_equal "grantedgranted", File.read(File.join(@project, "approvals.txt")), "canceling never ran the held call"
  end

  private

    def await_rho_approval(loop_id)
      await("an approval on loop #{loop_id}") do
        rho_loops.fetch(loop_id).tasks.find { |task| task.status == "needs_approval" }
      end
    end
end
