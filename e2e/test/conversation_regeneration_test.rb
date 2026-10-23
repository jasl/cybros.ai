require_relative "turn_test"

class TurnTest
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
