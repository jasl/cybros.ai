require "test_helper"
require "cgi/escape"
require "json"
require "securerandom"
require "time"
require "support/actor_provisioning"

# `deliver_at` ON THE INPUT ROW, THROUGH A DEPLOYED SYSTEM. A caller's "not before" is a clock on
# the row: accepted now, listed with its time, INVISIBLE to the drain until then — it neither heads
# nor blocks the queue — and, when due, drained and woken through the receipt's own path (the
# `DrainJob` the accept kicked AT the time; the minute sweep is the backstop). This lane proves the
# halves only a deployment can, on the dev lane and the mock, no rho, no grant: THE PREDICATE — for
# 1.5 s after a 3 s row is accepted on an IDLE conversation no reply turn opens and the row still
# lists; THE WAKE — within 10 s a reply turn settled with the mock's word, opened NOT BEFORE the
# row's time, and the row is gone (materialized); THE CLEAR — a 30 s row made due by
# `update(deliver_in: "0s")` drains within 5 s (the typed clear: never a null); THE CANCEL — a 30 s
# row `delete`d opens nothing (DELETE is the cancel); THE REFUSALS — a steer with a time, a time
# past the grace, a naive stamp (the wire refuses the ambiguity), and the LOOP door by the field's
# name (a loop's one turn is in flight: nothing waits behind it). The unit facts — the bounds, the
# envelope, the sweep's frontier, the author's standing re-read at materialization — are the kernel
# suites'.
class ScheduledInputTest < Minitest::Test
  # 120 requests a minute per identity: one read a second.
  POLL = 1.0
  MODEL = "dev/mock-text".freeze
  DELAY = 3
  HOLD = 1.5
  WAKE_TIMEOUT = 10
  CLEAR_TIMEOUT = 5
  QUIET = 2
  MONO = Process::CLOCK_MONOTONIC

  def setup
    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    E2E.hosts.start
    @workspace = @client.workspace(@client.workspaces.create(
      name: "Scheduled input #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    ).public_id)
    @chat = @workspace.conversations.conversation(
      @workspace.conversations.create(title: "Timed", idempotency_key: SecureRandom.uuid).public_id
    )
  end

  def test_a_timed_row_waits_for_its_time_then_drains_and_wakes_and_the_edit_surface_and_refusals_hold
    assert_nil @chat.fetch.active_turn_public_id, "an IDLE conversation: nothing runs before the row (decision 23)"

    accepted = timed("!mock reply=woke -- wake me", deliver_in: "#{DELAY}s")
    assert_equal "pending", accepted.state
    due_at = Time.iso8601(accepted.input.deliver_at)
    assert_in_delta Time.now + DELAY, due_at, 2, "the delay is resolved against the kernel's clock"
    listed = @chat.inputs.list.items.find { |row| row.public_id == accepted.public_id }
    assert_equal accepted.input.deliver_at, listed&.deliver_at, "the row lists with its time"

    # THE PREDICATE: before its time the row is not in the room — no reply
    # turn opens, and the row stays listed.
    held_until = Process.clock_gettime(MONO) + HOLD
    reads = 0
    while Process.clock_gettime(MONO) < held_until
      assert_empty assistant_turns, "before its time the row is neither the head nor a blocker: no reply turn"
      assert @chat.inputs.list.items.any? { |row| row.public_id == accepted.public_id }, "still listed, still pending"
      reads += 1
      sleep POLL
    end
    assert_operator reads, :>=, 1

    # THE WAKE: the receipt's own path, kicked at the time.
    reply = await_reply(after: -1, patience: WAKE_TIMEOUT, what: "the timed row's reply")
    assert_includes reply.text.to_s, "woke", "the mock spoke the row's word: #{reply.text.inspect}"
    assert_operator Time.iso8601(reply.created_at), :>=, due_at.floor, "the turn opened not before the row's time"
    refute @chat.inputs.list.items.any? { |row| row.public_id == accepted.public_id }, "materialized: the row is gone"

    # THE CLEAR: `deliver_in: "0s"` makes a 30 s row due now.
    after = assistant_turns.map(&:position).max
    second = timed("!mock reply=cleared -- now", deliver_in: "30s")
    edited = @chat.inputs.update(second.public_id, deliver_in: "0s")
    assert_operator Time.iso8601(edited.deliver_at), :<=, Time.now + 1, "due now"
    reply = await_reply(after: after, patience: CLEAR_TIMEOUT, what: "the cleared row's reply")
    assert_includes reply.text.to_s, "cleared"

    # THE CANCEL: DELETE is a scheduled row's cancel.
    third = timed("!mock reply=never -- never", deliver_in: "30s")
    @chat.inputs.delete(third.public_id)
    assert_empty @chat.inputs.list.items, "the listing is empty"
    positions = assistant_turns.map(&:position)
    sleep QUIET
    assert_equal positions, assistant_turns.map(&:position), "a deleted row opens nothing"

    # THE REFUSALS, by name.
    refused("deliver_at_not_steerable") do
      @chat.inputs.create(kind: "direct_reply", model: MODEL, text: "x", delivery_mode: "steer",
        deliver_in: "#{DELAY}s", idempotency_key: SecureRandom.uuid)
    end
    refused("deliver_at_in_past") do
      @chat.inputs.create(kind: "direct_reply", model: MODEL, text: "x", deliver_at: "2020-01-01T00:00:00Z",
        idempotency_key: SecureRandom.uuid)
    end
    refused("parameter_invalid") do
      @chat.inputs.create(kind: "direct_reply", model: MODEL, text: "x", deliver_at: "2026-09-16T09:00:00",
        idempotency_key: SecureRandom.uuid)
    end
    assert_empty @chat.inputs.list.items, "every refusal posts nothing"

    parked = parked_loop!
    error = refused("validation_failed") do
      parked.inputs.create(text: "later", delivery_mode: "queue", deliver_in: "#{DELAY}s",
        idempotency_key: SecureRandom.uuid)
    end
    assert_match(/deliver.at/i, error.message, "the loop door refuses the field by name")
    assert_empty parked.inputs.list.items
  ensure
    parked&.stop(force: true)
  end

  def test_postponing_a_blocked_head_immediately_releases_the_due_message_behind_it
    head = @chat.inputs.create(kind: "direct_reply", model: "dev/no-such-model", text: "later",
      idempotency_key: SecureRandom.uuid)
    blocked = await(patience: WAKE_TIMEOUT, what: "the unknown model to block the head") do
      row = @chat.inputs.list.items.find { |input| input.public_id == head.public_id }
      row if row&.blocked?
    end
    assert_equal "unknown_model", blocked.blocked_reason

    word = "an immediate word behind the blocked head"
    tail = @chat.inputs.create(text: word, idempotency_key: SecureRandom.uuid)
    # Let the tail's original wake meet the blocked head before the edit.
    # The kernel unit pin consumes that wake exactly; this deployment
    # check uses the existing quiet window because a repeated block emits
    # no new public event.
    sleep QUIET
    assert_equal [head.public_id, tail.public_id], @chat.inputs.list.items.map(&:public_id)
    refute @chat.turns.list.items.any? { |turn| turn.text == word }

    edited = @chat.inputs.update(head.public_id, model: MODEL, deliver_in: "1h")
    assert_equal "pending", edited.state
    assert_operator Time.iso8601(edited.deliver_at), :>, Time.now + 3_500

    turn = await(patience: CLEAR_TIMEOUT, what: "the due message to pass the postponed head") do
      @chat.turns.list.items.find { |row| row.kind == "message" && row.text == word }
    end
    assert_equal "user", turn.role
    remaining = @chat.inputs.list.items
    assert_equal [head.public_id], remaining.map(&:public_id)
    assert_equal "pending", remaining.first.state
    assert_equal edited.deliver_at, remaining.first.deliver_at
    assert_empty assistant_turns, "the postponed reply has not started"
  ensure
    @chat.inputs.delete(head.public_id) if head
  end

  private

    def timed(text, **schedule)
      accepted = @chat.inputs.create(kind: "direct_reply", model: MODEL, text: text,
        idempotency_key: SecureRandom.uuid, **schedule)
      refute_nil accepted.input.deliver_at, "a timed row carries the time the kernel holds"
      accepted
    end

    def assistant_turns = @chat.turns.list.items.select { |turn| turn.role == "assistant" }

    # A STANDALONE LOOP that stays running: its one round parks on a
    # kernel-held `ask` (a question for a person nobody answers), so its
    # door is open for the whole test and no runner is needed.
    def parked_loop!
      definition = @client.tools.definitions_for(["nexus.human.ask"]).first
      arguments = CGI.escape(JSON.generate("prompt" => "may I?"))
      created = @workspace.agent_loops.create(
        steps: [{ "model" => {
          "key" => "r1", "model" => { "model" => MODEL }, "tools" => [definition],
          "prompt" => "!mock tool_call=ask tool_args=#{arguments} -- hold",
        } }],
        approval_mode: "bypass", idempotency_key: SecureRandom.uuid
      )
      @workspace.agent_loop(created.agent_loop.public_id)
    end

    # The refusal's code, off the typed error the SDK raises for the
    # envelope; the error is answered so a caller can read its sentence.
    def refused(code)
      error = assert_raises(CybrosAgent::Api::Error) { yield }
      assert_equal code, error.code, "refused by name: #{error.message}"
      error
    end

    # The settled assistant turn past `after` within `patience` seconds;
    # a failed one fails HERE with its row.
    def await_reply(after:, patience:, what:)
      await(patience: patience, what: what) do
        newer = assistant_turns.select { |turn| turn.position > after }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed

        newer.find { |turn| turn.status == "completed" }
      end
    end

    def await(patience:, what:)
      deadline = Process.clock_gettime(MONO) + patience
      loop do
        found = yield
        return found if found

        flunk("the deployment never reached #{what} within #{patience} s") if Process.clock_gettime(MONO) > deadline
        sleep POLL
      end
    end
end
