require_relative "turn_test"

class TurnTest
  def test_regeneration_and_swipe_cancel_replaced_background_work_without_reviving_it
    boot_rho!
    arguments = background_code([
      { "ask" => { "prompt" => "Continue this background work?", "key" => "question" } },
      { "tool" => { "name" => "bash", "route" => rho_runner_route, "input" => { "command" => "sleep #{E2E::RhoDaemon::HOLD_SECONDS}" }, "key" => "delay" } },
    ])
    conversation, first_loop = rho_open("!mock tool_call=code tool_args=#{arguments} -- candidate answer")
    chat = steward_conversation(conversation)
    original = await_settled_reply(chat).items.last
    first_question = await_background_question(first_loop)
    assert_waiting_background_shell(first_loop)
    await_follower(conversation, loop: first_loop)

    regenerated = chat.turns.regenerate(original.public_id, idempotency_key: SecureRandom.uuid, model: MODEL)
    second_loop = regenerated.variant.run_public_id
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
    assert_equal first_loop, followed.fetch("run_public_id"),
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
    assert_equal second_loop, followed.fetch("run_public_id")
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
      @daemon.control(:get, "/followers").fetch("followers").find { |row| row.fetch("public_id") == conversation }
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
