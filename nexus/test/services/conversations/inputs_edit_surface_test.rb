require "test_helper"

# The waiting room's edit surface: edit-while-queued with the blocked-head unblock,
# steer-cancel-by-destroy, and exact-set reorder — every mutation narrated, every one kicking the
# drain.
class Conversations::InputsEditSurfaceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
  end

  def accept!(kind: "message", text: "hello", **overrides)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
      host: @conversation, acting_user: @user, kind: kind,
      role: "user", entries: [{ "text" => text }], visible_in_context: true,
      delivery_mode: "queue", context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
    assert_predicate result, :accepted?
    result.value
  end

  def update!(input, **overrides)
    Conversations::Inputs::Update.call(Conversations::Inputs::Update::Command.new(**{
      host: @conversation, input_public_id: input.public_id,
      acting_user: @user, expected_lock_version: nil, entries: nil,
      visible_in_context: nil, context_mode: nil, context_options: nil, provider_id: nil,
      model_ref: nil, reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
  end

  def drain! = Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

  test "edit-while-queued replaces content and execution facts, narrated" do
    input = accept!(text: "first draft")

    result = update!(input,
      entries: [{ "text" => "second draft" }], visible_in_context: false)

    assert_predicate result, :accepted?
    input.reload
    assert_equal "second draft", input.content_body.effective_text
    assert_not input.visible_in_context
    assert_equal "input_edited",
      @conversation.conversation_event_items.order(:sequence).last.item_type

    drain!
    turn = @conversation.conversation_turns.sole
    assert_equal "excluded_from_context", turn.visibility
    assert_equal "second draft",
      turn.active_variant.content_bodies.sole.effective_text,
      "materialization reads the edited facts"
  end

  test "editing a blocked head is the unblock path" do
    accept!(kind: "direct_reply", text: "reply", provider_id: "dev", model_ref: "nope")
    assert_equal 0, drain!
    blocked = @conversation.conversation_inputs.sole.reload
    assert_equal "blocked", blocked.state

    result = update!(blocked, model_ref: "mock-text")

    assert_predicate result, :accepted?
    assert_equal "pending", blocked.reload.state
    assert_nil blocked.blocked_reason
    assert_equal 1, drain!, "the drain re-judges the head with the fix"
    assert_equal "running", @conversation.conversation_turns.sole.status
  end

  test "the history intent edits while queued and the drain honors the edit" do
    accept!(text: "older history")
    accept!(text: "newest history")
    drain!
    reply = accept!(kind: "direct_reply", text: "the question",
      provider_id: "dev", model_ref: "mock-text")

    result = update!(reply, context_options: { "history" => { "max_entries" => 1 } })
    assert_predicate result, :accepted?
    assert_equal({ "history" => { "max_entries" => 1 } }, reply.reload.context_options)

    invalid = update!(reply, context_options: { "history" => { "max_entries" => -1 } })
    assert_equal :invalid, invalid.outcome
    assert_equal 1, reply.reload.context_options.dig("history", "max_entries"),
      "a refused intent leaves the stored intent standing"

    raw_flip = update!(reply, context_mode: "raw",
      entries: [{ "role" => "user",
                  "parts" => [{ "type" => "text", "text" => "q" }] }])
    assert_equal :invalid, raw_flip.outcome,
      "flipping to raw would strand the stored bound as a silent no-op"

    assert_equal 1, drain!
    request = @conversation.model_invocations.sole.content_bodies.find_by!(role: "request")
    texts = request.content_body_entries.map { |e| e.content_fragment.payload }
      .flat_map { |p| Array(p["parts"]).map { |part| part["text"] } }.join("\n")
    assert_includes texts, "newest history"
    assert_not_includes texts, "older history", "materialization reads the EDITED intent"
  end

  test "clearing the intent restores pristine and unlocks the raw flip" do
    reply = accept!(kind: "direct_reply", text: "the question",
      provider_id: "dev", model_ref: "mock-text")
    update!(reply, context_options: { "history" => { "max_entries" => 3 } })

    cleared = update!(reply, context_options: {})

    assert_predicate cleared, :accepted?
    assert_equal({}, reply.reload.context_options, "the clear gesture lands, not skipped as falsy")

    raw = update!(reply, context_mode: "raw",
      entries: [{ "role" => "user",
                  "parts" => [{ "type" => "text", "text" => "raw q" }] }])
    assert_predicate raw, :accepted?, "with no stranded bound, raw is reachable again"
  end

  test "the CAS refuses a stale edit and a content refusal leaves the row whole" do
    input = accept!(text: "original")

    stale = update!(input, expected_lock_version: 99, entries: [{ "text" => "x" }])
    assert_equal :stale_object, stale.outcome

    refused = update!(input, entries: Array.new(Nexus::SizeBounds.fetch(:body_entry_count_bound) + 1) { { "text" => "x" } })
    assert_equal :content_items_too_many, refused.outcome
    assert_equal "original", input.reload.content_body.effective_text,
      "the savepoint took back the whole edit"
  end

  test "a content-only edit bumps the lock so an armed fence can see it" do
    input = accept!(text: "v1")
    before = input.lock_version

    update!(input, entries: [{ "text" => "v2" }])

    assert_operator input.reload.lock_version, :>, before,
      "content lives off-row; the CAS must not be hollow"
    stale = update!(input, expected_lock_version: before, entries: [{ "text" => "v3" }])
    assert_equal :stale_object, stale.outcome
    assert_equal "v2", input.reload.content_body.effective_text
  end

  test "destroying a steering row is the steer-cancel verb" do
    actor = Actors::Resolve.member(account: @account, user: @user)
    ConversationTurn.create!(
      account: @account, conversation: @conversation, position: 0,
      kind: "direct_reply", role: "assistant", status: "running",
      speaker_actor: actor, control_owner_user: @user
    )
    steer = accept!(delivery_mode: "steer", text: "steer me")
    assert_equal "steering", steer.state

    held = update!(steer, entries: [{ "text" => "changed" }])
    assert_equal :steering_held, held.outcome, "a held steer edits nowhere"

    result = Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: @conversation, input_public_id: steer.public_id, acting_user: @user
    ))

    assert_predicate result, :accepted?
    assert_equal 0, ConversationInput.count
    narration = @conversation.conversation_event_items.order(:sequence).last
    assert_equal "input_deleted", narration.item_type
    assert narration.payload["steer_canceled"]
  end

  test "reorder takes the exact set or nothing" do
    first = accept!(text: "a")
    second = accept!(text: "b")
    third = accept!(text: "c")

    partial = Conversations::Inputs::Reorder.call(Conversations::Inputs::Reorder::Command.new(
      host: @conversation, acting_user: @user,
      ordered_public_ids: [second.public_id, first.public_id]
    ))
    assert_equal :queue_changed, partial.outcome, "a partial list reorders nothing"

    result = Conversations::Inputs::Reorder.call(Conversations::Inputs::Reorder::Command.new(
      host: @conversation, acting_user: @user,
      ordered_public_ids: [third.public_id, first.public_id, second.public_id]
    ))

    assert_predicate result, :accepted?
    assert_equal %w[c a b],
      @conversation.conversation_inputs.order(:queue_position)
        .map { |i| i.content_body.effective_text }
    assert_equal 3, drain!
    assert_equal %w[c a b],
      @conversation.conversation_turns.order(:position)
        .map { |t| t.active_variant.content_bodies.sole.effective_text },
      "the new order IS the materialization order"
  end

  # KERNEL-ORIGIN ROWS ARE IMMUTABLE TO THE PERSON: the edit, the delete and the reorder refuse by
  # name; `reorder` ranges over the person's rows alone and never rewrites a kernel row's position.
  def kernel_mail!(origin: ConversationInput::TASK_RESULT_ORIGIN)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
      host: @conversation, acting_user: @user,
      entries: [{ "text" => "<task_result task=\"r2t0\" status=\"completed\">done</task_result>" }],
      origin: origin, sender_conversation_public_id: @conversation.public_id
    ))
    assert_predicate result, :accepted?
    result.value
  end

  # A PEER'S SEND IS A PRINCIPAL'S WORD: the recipient's queue is theirs to manage, so a principal
  # with standing edits, deletes and reorders an agent's `send` like any caller row; immutability
  # protects the kernel's FACTS only — the `child` receipt stays immutable.
  test "an agent's send is editable, deletable and reorderable; a child receipt is not" do
    agent = users(:agent)
    sender = Conversation.create!(workspace: @workspace, creating_user: agent)
    sent = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
      host: @conversation, acting_user: agent, entries: [{ "text" => "peer" }],
      sender_conversation_public_id: sender.public_id
    )).value
    assert_equal "agent", sent.origin
    child = kernel_mail!(origin: ConversationInput::CHILD_ORIGIN)
    own = accept!(text: "mine")

    assert_predicate update!(sent, entries: [{ "text" => "rewritten" }]), :accepted?
    assert_equal "rewritten", sent.reload.content_body.effective_text
    assert_equal :kernel_input_immutable, update!(child, entries: [{ "text" => "no" }]).outcome
    assert_equal :kernel_input_immutable, reorder!(child, own, sent).outcome
    assert_predicate reorder!(own, sent), :accepted?
    assert_equal [child, own, sent], @conversation.conversation_inputs.in_read_order.to_a

    assert_predicate Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: @conversation, input_public_id: sent.public_id, acting_user: @user
    )), :accepted?
    assert_equal :kernel_input_immutable, Conversations::Inputs::Destroy.call(
      Conversations::Inputs::Destroy::Command.new(
        host: @conversation, input_public_id: child.public_id, acting_user: @user
      )
    ).outcome
  end

  def reorder!(*inputs)
    Conversations::Inputs::Reorder.call(Conversations::Inputs::Reorder::Command.new(
      host: @conversation, acting_user: @user, ordered_public_ids: inputs.map(&:public_id)
    ))
  end

  test "kernel-origin rows refuse the whole edit surface by name" do
    first = accept!(text: "a")
    mail = kernel_mail!
    second = accept!(text: "b")

    assert_equal :kernel_input_immutable, update!(mail, entries: [{ "text" => "rewritten" }]).outcome
    assert_equal :kernel_input_immutable, Conversations::Inputs::Destroy.call(
      Conversations::Inputs::Destroy::Command.new(
        host: @conversation, input_public_id: mail.public_id, acting_user: @user
      )
    ).outcome
    assert_equal :kernel_input_immutable, reorder!(mail, second, first).outcome
    assert_equal :queue_changed, reorder!(second).outcome, "the person's rows are still the exact set"

    result = reorder!(second, first)
    assert_predicate result, :accepted?
    assert_equal [1, 0, 2], [mail, second, first].map { |row| row.reload.queue_position },
      "the person's rows swap among their own positions; the kernel row's is untouched"
    assert_equal [mail, second, first], @conversation.conversation_inputs.in_read_order.to_a
    assert_equal 3, ConversationInput.count
  end

  test "the bin refuses the whole edit surface" do
    input = accept!
    @conversation.reload.update!(archived_at: Time.current)

    assert_equal :conversation_archived, update!(input.reload, entries: [{ "text" => "x" }]).outcome
    assert_equal :conversation_archived,
      Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
        host: @conversation, input_public_id: input.public_id, acting_user: @user
      )).outcome
  end

  # THE CLOCK ON THE EDIT SURFACE: no tri-state — nil is UNTOUCHED, the kernel's rule for every
  # update member; a Time reschedules under the door's own two bounds and retains a wake AT the new
  # time beside the immediate queue wake; a time inside the grace (the wire's `deliver_in: "0s"`) is
  # due and the existing post-commit kick drains it now. `rho inputs rm` / DELETE is the cancel,
  # unchanged.
  def drain_kicks = enqueued_jobs.select { |job| job[:job] == Conversations::Inputs::DrainJob }

  test "deliver_at: nil is untouched, a future time reschedules and kicks at it, a due time clears and kicks now" do
    at = 1.hour.from_now.change(usec: 0)
    input = accept!(text: "later", deliver_at: at)
    clear_enqueued_jobs

    assert_predicate update!(input, entries: [{ "text" => "later, edited" }]), :accepted?
    assert_equal at, input.reload.deliver_at, "an edit that names no time keeps the row's"
    assert_equal "later, edited", input.content_body.effective_text
    assert_equal 0, drain!, "still before its time: not in the room"

    later = 2.hours.from_now.change(usec: 0)
    clear_enqueued_jobs
    assert_enqueued_jobs 2, only: Conversations::Inputs::DrainJob do
      assert_predicate update!(input, deliver_at: later), :accepted?
    end
    assert_equal later, input.reload.deliver_at
    assert_nil drain_kicks.first[:at], "other ready inputs may drain immediately"
    assert_equal [[@conversation.id], later.to_f], drain_kicks.last.values_at(:args, :at),
      "the scheduled input still wakes at its new time"

    clear_enqueued_jobs
    assert_enqueued_jobs 1, only: Conversations::Inputs::DrainJob do
      assert_predicate update!(input, deliver_at: Time.current), :accepted?
    end
    assert_nil drain_kicks.sole[:at], "due now: the post-commit kick, at once"
    assert_equal 1, drain!, "the row is in the room at the next boundary"
  end

  test "an edit's time is judged by the door's two bounds, and a kernel row is nobody's to reschedule" do
    input = accept!(text: "x")

    assert_equal :deliver_at_in_past, update!(input, deliver_at: 3.minutes.ago).outcome
    assert_equal :deliver_at_too_far, update!(input, deliver_at: 11.years.from_now).outcome
    assert_nil input.reload.deliver_at, "a refused edit changes nothing"
    assert_predicate update!(input, deliver_at: 1.minute.ago), :accepted?, "inside the grace: due"
    assert_predicate update!(input, deliver_at: 9.years.from_now), :accepted?

    mail = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
      host: @conversation, acting_user: @user, entries: [{ "text" => "done" }],
      origin: "task_result", sender_conversation_public_id: SecureRandom.uuid_v7
    )).value
    assert_equal :kernel_input_immutable, update!(mail, deliver_at: 1.hour.from_now).outcome
  end

  # A row blocks only at materialization, which only a due row reaches, and an edit that sets a
  # FUTURE time on a blocked head returns it to `pending` first — so a `blocked` row always has a
  # past or nil `deliver_at`, and the drain's `due` merge never hides a blocker.
  test "a blocked head edited to a future time is pending and leaves the room until then" do
    accept!(kind: "direct_reply", text: "reply", provider_id: "dev", model_ref: "nope")
    assert_equal 0, drain!
    blocked = @conversation.conversation_inputs.sole.reload
    assert_equal "blocked", blocked.state

    at = 1.hour.from_now.change(usec: 0)
    assert_predicate update!(blocked, model_ref: "mock-text", deliver_at: at), :accepted?

    assert_equal ["pending", nil, at], [blocked.reload.state, blocked.blocked_reason, blocked.deliver_at]
    assert_equal 0, drain!, "the fixed row waits for its time"
    assert_empty @conversation.conversation_turns
  end

  test "rescheduling a blocked head immediately releases the ready input behind it" do
    blocked = accept!(kind: "direct_reply", text: "later reply", provider_id: "dev", model_ref: "nope")
    ready = accept!(text: "ready now")
    perform_enqueued_jobs(only: Conversations::Inputs::DrainJob, at: Time.current)
    assert_equal "blocked", blocked.reload.state
    assert_empty @conversation.conversation_turns

    at = 1.hour.from_now.change(usec: 0)
    assert_predicate update!(blocked, model_ref: "mock-text", deliver_at: at), :accepted?
    perform_enqueued_jobs(only: Conversations::Inputs::DrainJob, at: Time.current)

    assert_not ConversationInput.exists?(ready.id), "moving the head into the future releases today's work"
    assert_equal "ready now", @conversation.conversation_turns.sole.active_variant.content_bodies.sole.effective_text
    assert_equal "pending", blocked.reload.state
    assert_equal at, blocked.deliver_at

    DatabaseClock.stub(:now, at) do
      perform_enqueued_jobs(only: Conversations::Inputs::DrainJob, at: at)
    end
    assert_not ConversationInput.exists?(blocked.id)
    assert_equal %w[message direct_reply], @conversation.conversation_turns.order(:position).pluck(:kind)
    Conversations::Inputs::DrainJob.perform_now(@conversation.id)
    assert_equal 2, @conversation.conversation_turns.count, "another wake never repeats either input"
  end
end
