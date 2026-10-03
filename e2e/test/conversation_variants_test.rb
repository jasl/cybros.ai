require_relative "conversation_turn_test"

class ConversationTurnTest
  def test_editing_a_held_tail_replaces_the_followed_failure_with_the_manual_answer
    boot_rho!
    # A terminal provider refusal creates the held candidate without unrelated transport retries.
    conversation, loop_id = rho_open("!mock error=400 -- hold this answer")
    chat = steward_conversation(conversation)
    held = await_rho_loop(loop_id, "needs_attention")
    original = await("the held turn's failed timeline and follower") do
      turn = chat.turns.list.items.last
      followed = variant_follower(conversation)
      turn if turn&.status == "failed" && followed["status"] == "failed" && followed["attention"]
    end
    failed_task = held.tasks.find { |task| task.status == "failed" }
    refute_nil failed_task, "the hold must have an adjudicable failure"

    edited = chat.turns.edit(original.public_id, text: "The person supplied this answer.")
    event = await_variant_event(chat, edited.public_id, "edited")
    followed = await_variant_followed(conversation, event.sequence)
    assert_equal "completed", followed.fetch("status"),
      "rho consumed the manual edit but still reports the held failure: #{followed.inspect}"
    assert_equal edited.content, followed.fetch("text")
    assert_equal original.public_id, followed.fetch("turn")
    assert_nil followed["loop"], "a manual candidate is not backed by the old loop"
    assert_nil followed["attention"]
    assert_empty followed.fetch("tasks"), "the old failure is no longer the displayed candidate's task"
    assert followed.fetch("complete")

    deck = chat.turns.variants(original.public_id)
    assert_equal edited.public_id, deck.active.public_id
    assert_equal "edit", deck.active.source
    assert_equal "completed", chat.turns.list.items.last.status
    assert_includes deck.items.map(&:public_id), original.active_variant.public_id
    task = rho_loops.agent_loop(loop_id).tasks_context(failed_task.key)
    %i[retry abandon].each do |action|
      error = assert_raises(CybrosAgent::Api::Conflict) { task.public_send(action) }
      assert_equal "not_adjudicable", error.code
    end
  end

  def test_regeneration_and_swipe_cancel_replaced_background_work_without_reviving_it
    boot_rho!
    script = <<~JS
      g.ask({prompt: "Continue this background work?", key: "question"});
      g.tool({name: "bash", input: {command: "sleep #{E2E::RhoDaemon::HOLD_SECONDS}"}, key: "delay"});
    JS
    arguments = CGI.escape(JSON.generate("script" => script))
    conversation, first_loop = rho_open("!mock tool_call=compose tool_args=#{arguments} -- candidate answer")
    chat = steward_conversation(conversation)
    original = await_settled_reply(chat).items.last
    first_question = await_background_question(first_loop)
    assert_waiting_background_shell(first_loop)
    await_follower(conversation, loop: first_loop)

    regenerated = chat.turns.regenerate(original.public_id, model: MODEL)
    second_loop = regenerated.variant.agent_loop_public_id
    second_question = await_background_question(second_loop)
    assert_waiting_background_shell(second_loop)
    first_canceled = await_canceled_background(first_loop, first_question.key)
    deck = await_full_deck(chat, original.public_id)
    assert_equal regenerated.variant.public_id, deck.active.public_id
    await_follower(conversation, loop: second_loop)

    selected = activate_from_rho(conversation, chat, original.public_id, original.active_variant.public_id)
    assert_equal original.active_variant.content, selected.content, "regeneration retains the original published answer"
    second_canceled = await_canceled_background(second_loop, second_question.key)
    event = await_variant_event(chat, selected.public_id, "activated")
    followed = await_variant_followed(conversation, event.sequence)
    assert_equal first_loop, followed.fetch("loop"),
      "rho consumed the swipe but still follows the other candidate: #{followed.inspect}"
    assert_equal original.public_id, followed.fetch("turn")
    assert_equal "completed", followed.fetch("status")
    assert_equal selected.content, followed.fetch("text")
    assert followed.fetch("complete")
    current = rho_loops.fetch(first_loop)
    assert_equal current.tasks.map { |task| [task.key, task.kind, task.status] }.sort,
      followed.fetch("tasks").map { |task| task.values_at("task_key", "kind", "status") }.sort
    assert_nil followed["attention"], "the selected candidate's canceled question is no longer actionable"
    assert_equal selected.public_id, chat.turns.variants(original.public_id).active.public_id

    selected = activate_from_rho(conversation, chat, original.public_id, regenerated.variant.public_id)
    assert_equal deck.active.content, selected.content, "swiping away retains the alternative's published answer"
    assert_equal "completed", chat.turns.list.items.last.status, "the published turn stays completed"
    event = await_variant_event(chat, selected.public_id, "activated")
    followed = await_variant_followed(conversation, event.sequence)
    assert_equal second_loop, followed.fetch("loop")
    assert_equal selected.content, followed.fetch("text"), "the completed answer remains readable after its work was canceled"
    assert_equal "completed", followed.fetch("status")
    assert followed.fetch("complete")
    assert_nil followed["attention"]

    [[first_loop, first_canceled], [second_loop, second_canceled]].each do |loop, canceled|
      assert_equal task_states(canceled), task_states(rho_loops.fetch(loop)),
        "selecting a completed candidate must not restart any canceled work"
    end
  end

  private

    def activate_from_rho(conversation, chat, turn, variant)
      output, status = @daemon.cli("activate", conversation, turn, variant)
      assert_predicate status, :success?, "rho activate failed:\n#{output}"
      assert_match(/^variant:\s+#{Regexp.escape(variant)} active$/, output)
      selected = chat.turns.variants(turn).active
      assert_equal variant, selected.public_id
      selected
    end

    def await_canceled_background(loop_id, question_key)
      row = await("the replaced candidate's background work canceled on #{loop_id}") do
        current = rho_loops.fetch(loop_id)
        question = current.tasks.find { |task| task.key == question_key }
        shell = current.tasks.find { |task| task.tool_name == "bash" }
        current if current.status == "canceled" && question&.status == "canceled" && shell&.status == "canceled"
      end
      assert_equal "canceled", row.status, "the execution ends after its outstanding background work is canceled"
      row
    end

    def assert_waiting_background_shell(loop_id)
      shell = rho_loops.fetch(loop_id).tasks.find { |task| task.tool_name == "bash" }
      refute_nil shell, "the background graph must contain the shell step"
      assert_equal "waiting", shell.status, "the unanswered question keeps the shell from running"
    end

    def task_states(loop_row) = loop_row.tasks.map { |task| [task.key, task.kind, task.status] }.sort

    def variant_follower(conversation)
      @daemon.control(:get, "/loops").fetch("loops").find { |row| row.fetch("public_id") == conversation }
    end

    def await_variant_event(chat, variant, action)
      await("the #{action} candidate on the conversation feed") do
        chat.events(limit: 200).find do |event|
          event.type == "turn_variant" && event.payload["variant_public_id"] == variant && event.payload[action]
        end
      end
    end

    def await_variant_followed(conversation, sequence)
      await("rho consuming the candidate selection") do
        row = variant_follower(conversation)
        row if row.fetch("sequence") >= sequence
      end
    end

    def await_background_question(loop_id)
      await("the live background question on #{loop_id}") do
        rho_loops.fetch(loop_id).tasks.find { |task| task.kind == "await_task" && task.status == "awaiting_input" }
      end
    end
end
