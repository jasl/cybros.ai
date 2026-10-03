require "test_helper"

# The one front door: acceptance writes the durable waiting-room row and
# its UNSEALED body, and nothing else — materialization is the drain lane's
# job. Every refusal is synchronous and leaves no trace.
class Conversations::InputsCreateTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
  end

  def command(**overrides)
    Conversations::Inputs::Create::Command.new(**{
      host: @conversation, acting_user: @user, kind: "message",
      role: "user", entries: [{ "text" => "hello" }], visible_in_context: true,
      delivery_mode: "queue", context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides))
  end

  def create!(**overrides)
    Conversations::Inputs::Create.call(command(**overrides))
  end

  def build_running_turn(kind: "direct_reply", role: "assistant")
    actor = Actors::Resolve.member(account: @account, user: @user)
    ConversationTurn.create!(
      account: @account, conversation: @conversation, position: 0,
      kind: kind, role: role, status: "running",
      speaker_actor: actor, control_owner_user: @user
    )
  end

  test "acceptance queues the row with its unsealed body and a resolved member speaker" do
    result = create!

    assert_predicate result, :accepted?
    input = result.value
    assert_equal 0, input.queue_position
    assert_equal "pending", input.state
    assert_equal "queue", input.delivery_mode
    assert_equal @user.id, input.authoring_user_id

    speaker = input.speaker_actor
    assert_equal "member", speaker.kind
    assert_equal @user.public_id, speaker.external_id

    body = input.content_body
    assert_not body.sealed?, "content stays editable while queued; materialization seals"
    assert_equal "hello", body.effective_text

    narration = @conversation.conversation_event_items.sole
    assert_equal "input_accepted", narration.item_type
    assert_equal input.public_id, narration.payload.fetch("input_public_id"),
      "acceptance narrates atomically with the row"
    assert_equal({ "kind" => "human", "handle" => @user.handle, "display_name" => @user.display_name },
      narration.payload.fetch("authored_by"), "every row names its author: kind, handle, display name")
    assert_equal "person", narration.payload.fetch("origin")
    assert_not narration.payload.key?("sender_conversation_public_id"), "a person's word carries no sender stamp"

    second = create!(entries: [{ "text" => "again" }])
    assert_equal 1, second.value.queue_position, "FIFO positions allocate under the lock"
    assert_equal speaker.id, second.value.speaker_actor_id, "the member actor is resolved once"
  end

  test "the caller-authored bound refuses synchronously at capacity" do
    @conversation.update!(input_queue_limit: 2)
    2.times { assert_predicate create!, :accepted? }

    result = create!

    assert_equal :input_queue_full, result.outcome
    assert_equal 2, ConversationInput.count
  end

  # KERNEL MAIL: the two privileges no door admits — the sender stamp and the `origin` word — with
  # the loop and task key retaining the execution owner; always `queue`, never a steer. The helper
  # stays a `message` (the flat shape a child notice keeps): it tests the stamps, not the wake.
  def kernel_mail!(host: @conversation, by: @user, source: nil,
                   entries: [{ "text" => "<task_result task=\"r2t0\" status=\"completed\">done</task_result>" }], **surface)
    source ||= completed_source(host, by)
    Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
      host: host, acting_user: by, entries: entries,
      origin: ConversationInput::TASK_RESULT_ORIGIN, sender_conversation_public_id: host.public_id,
      agent_loop_public_id: source.public_id, task_key: "r2t0", **surface
    ))
  end

  def completed_source(host, by)
    source = create_loop_backed_turn(conversation: host, acting_user: by,
      turn_status: "completed", variant_status: "completed", loop_status: "completed").agent_loop
    source.update!(completed_at: Time.current, delivered_at: Time.current)
    host.update!(active_turn: nil)
    source
  end

  test "the kernel command stamps sender and origin, narrates its sourcing, and is not counted by the bound" do
    source = completed_source(@conversation, @user)
    result = kernel_mail!(source: source)
    assert_predicate result, :accepted?
    mail = result.value
    assert_equal %w[message user queue pending], [mail.kind, mail.role, mail.delivery_mode, mail.state],
      "kernel mail queues, never steers"
    assert_equal "task_result", mail.origin
    assert_equal @conversation.public_id, mail.sender_conversation_public_id
    assert_predicate mail, :visible_in_context?

    narration = @conversation.conversation_event_items.sole.payload
    assert_equal "task_result", narration.fetch("origin")
    assert_equal source.public_id, narration.fetch("agent_loop_public_id")
    assert_equal "r2t0", narration.fetch("task_key")
    assert_equal [source.public_id, "r2t0"], mail.values_at(:sender_agent_loop_public_id, :sender_task_key)
    assert_equal @conversation.public_id, narration.fetch("sender_conversation_public_id"),
      "the sender stamp rides the payload as it rides the row"
    assert_equal({ "kind" => "human", "handle" => @user.handle, "display_name" => @user.display_name },
      narration.fetch("authored_by"), "the kernel's mail is authored by the loop's creator, kind recorded")

    assert_equal 0, @conversation.conversation_inputs.caller_authored.count, "not counted against the bound"
    @conversation.reload.update!(input_queue_limit: 1)
    assert_predicate create!, :accepted?, "the mail took no slot from the caller"
    assert_equal :input_queue_full, kernel_mail!.outcome, "but a full queue refuses the mail like any row"
    assert_equal 2, ConversationInput.count
  end

  # The receipt's shape: a kernel-stamped `direct_reply` on the surface the mailing loop read off
  # itself — the row's own validations still judge it, so a name the declaring profile does not
  # declare refuses the mail as it would a person's word.
  test "a kernel reply carries the surface it was given and refuses what the profile does not declare" do
    result = kernel_mail!(kind: "direct_reply", provider_id: "dev", model_ref: "mock-text",
      reasoning_effort: "low")
    assert_predicate result, :accepted?
    mail = result.value
    assert_equal %w[direct_reply user queue pending], [mail.kind, mail.role, mail.delivery_mode, mail.state]
    assert_equal %w[dev mock-text low], [mail.provider_id, mail.model_ref, mail.reasoning_effort]
    assert_nil mail.tool_names
    assert_nil mail.approval_mode

    refused = kernel_mail!(kind: "direct_reply", provider_id: "dev", model_ref: "mock-text",
      tool_names: ["nope"])
    assert_equal :invalid, refused.outcome
    assert refused.record.errors.of_kind?(:tool_names, :not_declared)
  end

  test "kernel mail lands in an archived conversation and is refused on a tombstoned one" do
    @conversation.update!(archived_at: Time.current)
    assert_equal :conversation_archived, create!.outcome
    assert_predicate kernel_mail!, :accepted?, "a result lands as a subagent's notice does"

    @conversation.update!(tombstoned_at: Time.current)
    assert_equal :not_found, kernel_mail!.outcome
  end

  test "a caller's row reads its author's kind and no sender stamp; the presenter shows both on the mail" do
    caller = create!.value
    assert_equal "person", caller.origin
    assert_nil caller.sender_conversation_public_id
    assert_equal "person", AgentAPI::ConversationPresenter.input(caller).fetch(:origin),
      "always present on an input: the source kind, never read by presence"
    assert_equal "person", @conversation.conversation_event_items.sole.payload.fetch("origin")

    shown = AgentAPI::ConversationPresenter.input(kernel_mail!.value)
    assert_equal "task_result", shown.fetch(:origin)
    assert_equal @conversation.public_id, shown.fetch(:sender_conversation_public_id)
  end

  # THE STAMPED CONSTRUCTOR FAMILY: `kernel` is the kernel's own receipt — origin in the kernel set
  # or it raises — and `sent` is a PRINCIPAL'S row carrying the kernel's stamps, its origin derived
  # from the author's kind: human → `person`, agent → `agent`. A send is judged as the caller it is
  # (the level, the bin, the bound).
  test "Command.sent stamps a principal's row and derives its origin from the author's kind" do
    agent = users(:agent)
    sender = Conversation.create!(workspace: @workspace, creating_user: agent)
    sending_loop = completed_source(sender, agent).public_id

    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
      host: @conversation, acting_user: agent, kind: "direct_reply", entries: [{ "text" => "from a peer" }],
      delivery_mode: "queue", sender_conversation_public_id: sender.public_id,
      agent_loop_public_id: sending_loop, task_key: "r1t0"
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    row = result.value
    assert_equal "agent", row.origin
    assert_equal sender.public_id, row.sender_conversation_public_id
    assert_equal sending_loop, row.sender_agent_loop_public_id
    assert_equal "r1t0", row.sender_task_key
    assert_equal agent.id, row.authoring_user_id, "the author is the SENDER with its kind recorded"
    assert_not row.kernel_origin?
    assert_equal 1, @conversation.conversation_inputs.caller_authored.count, "a send counts against the bound"
    payload = @conversation.conversation_event_items.sole.payload
    assert_equal ["agent", sending_loop, "r1t0"], payload.values_at("origin", "agent_loop_public_id", "task_key")

    by_person = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
      host: @conversation, acting_user: @user, entries: [{ "text" => "hi" }],
      sender_conversation_public_id: sender.public_id
    ))
    assert_equal "person", by_person.value.origin

    @conversation.update!(archived_at: Time.current)
    assert_equal :conversation_archived, Conversations::Inputs::Create.call(
      Conversations::Inputs::Create::Command.sent(
        host: @conversation, acting_user: agent, entries: [{ "text" => "late" }],
        sender_conversation_public_id: sender.public_id
      )
    ).outcome, "the bin refuses a send by origin, never admits it by stamp"
    assert_predicate kernel_mail!(origin: ConversationInput::CHILD_ORIGIN), :accepted?,
      "the kernel's child notice passes the bin"
  end

  test "an agent author's plain word reads agent" do
    agent = users(:agent)
    result = create!(acting_user: agent)
    assert_predicate result, :accepted?, result.outcome.to_s
    assert_equal "agent", result.value.origin
  end

  test "both freshness fences answer at accept time" do
    assert_equal :stale_context, create!(expected_context_revision: 5).outcome
    assert_predicate create!(expected_context_revision: @conversation.context_revision), :accepted?

    assert_equal :stale_timeline,
      create!(expected_tail_turn_public_id: SecureRandom.uuid).outcome

    tail = build_running_turn
    assert_predicate create!(expected_tail_turn_public_id: tail.public_id), :accepted?
  end

  # THE DOOR'S STANDING UNDER THE LEVELS: a caller writes at `full`; the kernel's own mail — stamped
  # BY NAME (`kernel?`), never by origin presence — is exempt from the level and never from the
  # workspace; a caller-authored row carrying an origin the kernel does not own (`agent`) is judged
  # as the caller it is.
  test "the door reads the level: read refuses a caller, admits kernel mail, and a caller-authored origin is no stamp" do
    reader = users(:owner)
    @conversation.update!(access_default: "read")

    assert_equal :not_authorized, create!(acting_user: reader).outcome
    assert_predicate kernel_mail!(by: reader), :accepted?,
      "the loop's creator may hold read while the answerer's engine mails its receipt"
    assert_equal :not_authorized, create!(acting_user: reader, origin: "agent",
      sender_conversation_public_id: @conversation.public_id).outcome,
      "an origin the kernel does not own is a caller's row"
    assert_raises(ArgumentError) { kernel_mail!(by: reader, origin: "agent") }
    assert_equal %w[task_result child], ConversationInput::KERNEL_ORIGINS

    @conversation.conversation_access_entries.create!(user: reader, level: "full")
    assert_predicate create!(acting_user: reader), :accepted?

    @conversation.conversation_access_entries.find_by!(user: reader).update!(level: "none")
    assert_equal :not_authorized, create!(acting_user: reader).outcome
    assert_predicate create!, :accepted?, "the creator is full by derivation"
  end

  test "a standalone loop's door keeps the workspace rule: no level to read" do
    agent_loop = AgentLoop.create!(workspace: @workspace, creating_user: @user, approval_mode: "bypass",
      status: "running")
    result = loop_input!(agent_loop, acting_user: users(:owner), text: "go")
    assert_predicate result, :accepted?, result.outcome.to_s
  end

  test "recipient gates: archived names its reason, tombstoned answers absence" do
    @conversation.update!(archived_at: Time.current)
    assert_equal :conversation_archived, create!.outcome

    @conversation.update!(tombstoned_at: Time.current)
    assert_equal :not_found, create!.outcome

    assert_equal :not_authorized,
      create!(host: Conversation.create!(
        workspace: workspaces(:personal), creating_user: users(:curator)
      )).outcome
  end

  test "steer joins the in-flight turn; on idle it falls back to the queue" do
    # STEER-ON-IDLE IS NOT A REFUSAL: with no reply in flight there is nothing to redirect, but the
    # caller's words are still worth delivering, so the row queues like any other input.
    idle = create!(delivery_mode: "steer")
    assert_predicate idle, :accepted?
    assert_equal "pending", idle.value.state
    assert_nil idle.value.steering_target_turn_id
    idle.value.destroy!

    turn = build_running_turn
    result = create!(delivery_mode: "steer")

    assert_predicate result, :accepted?
    assert_equal "steering", result.value.state
    assert_equal turn.id, result.value.steering_target_turn_id
    assert_equal 1, @conversation.conversation_inputs.caller_authored.count,
      "a held steer counts against the caller bound"
  end

  # A between-turn compaction summary is the ONE active turn while its summarizer runs, and a
  # person's words must never bind to it — only the reply in flight is a steer's binding.
  test "a steer binds only to an active direct_reply; any other active turn queues it" do
    build_running_turn(kind: "compaction_summary", role: "assistant")
    result = create!(delivery_mode: "steer")

    assert_predicate result, :accepted?
    assert_equal "pending", result.value.state
    assert_nil result.value.steering_target_turn_id
  end

  test "raw mode belongs to the reply lane" do
    result = create!(context_mode: "raw")

    assert_equal :invalid, result.outcome
    assert result.record.errors.of_kind?(:context_mode, :invalid),
      "a message IS content; only the reply lane compiles"

    assert_predicate create!(kind: "direct_reply", context_mode: "raw",
      provider_id: "dev", model_ref: "mock-text"), :accepted?
  end

  test "the history intent is a closed vocabulary, refused at the front door" do
    reply = { kind: "direct_reply", provider_id: "dev", model_ref: "mock-text" }
    assert_predicate create!(
      **reply,
      context_options: { "history" => { "max_entries" => 5, "token_budget_share" => 0.5 } }
    ), :accepted?

    [
      { "history" => { "max_entries" => -1 } },
      { "history" => { "max_entries" => 201 } },
      { "history" => { "token_budget_share" => 1.5 } },
      { "history" => { "positions" => [1, 2] } },
      { "history" => {} },
      { "compaction" => {} },
      "history",
      { "reasoning_replay" => { "mode" => "sometimes" } },
      { "reasoning_replay" => {} },
      { "reasoning_replay" => "all" },
      { "inline" => [] },
      { "inline" => [{ "role" => "tool", "text" => "x" }] },
      { "inline" => [{ "role" => "user", "text" => "" }] },
      { "inline" => [{ "role" => "user", "text" => "x", "position" => "middle" }] },
      { "inline" => [{ "role" => "user", "text" => "x", "extra" => 1 }] },
      { "inline" => "persona" },
      { "inline" => Array.new(17) { { "role" => "user", "text" => "x" } } },
    ].each do |bad|
      result = create!(**reply, context_options: bad)
      assert_equal :invalid, result.outcome, bad.inspect
      assert result.record.errors.of_kind?(:context_options, :invalid)
    end

    assert_predicate create!(
      **reply, context_options: { "reasoning_replay" => { "mode" => "all" } }
    ), :accepted?
    assert_predicate create!(
      **reply, context_options: { "inline" => [
        { "role" => "developer", "text" => "persona" },
        { "role" => "user", "text" => "note", "position" => "tail" },
      ] }
    ), :accepted?

    assert_equal :invalid,
      create!(context_options: { "history" => { "max_entries" => 1 } }).outcome,
      "intent on a message is a bound that would silently do nothing — raw mode's twin"

    assert_equal :invalid,
      create!(**reply, context_mode: "raw",
        entries: [{ "role" => "user",
                    "parts" => [{ "type" => "text", "text" => "q" }] }],
        context_options: { "history" => { "max_entries" => 1 } }).outcome,
      "raw skips the compile — the same silently-dead bound refuses"
  end

  test "a content refusal takes the whole acceptance back — no orphaned row" do
    result = create!(entries: Array.new(Nexus::SizeBounds.fetch(:body_entry_count_bound) + 1) { { "text" => "x" } })

    assert_equal :content_items_too_many, result.outcome
    assert_equal 0, ConversationInput.count
    assert_equal 0, ContentBody.count
  end

  # ── the addressee ───────────

  # A second agent of the account beside the fixture one — two engines a
  # room can address.
  def peer_agent = @peer_agent ||= create_agent_member(display_name: "Peer", agent_identifier: "peer-agent")

  def room_answered_by(answerer)
    Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: answerer)
  end

  test "to: names the answerer by @handle or public id, defaults to the conversation's, and rides the row and its narration" do
    room = room_answered_by(users(:agent))

    unnamed = create!(host: room)
    assert_predicate unnamed, :accepted?
    assert_equal users(:agent), unnamed.value.answering_user, "unnamed: the conversation's answering profile"

    by_handle = create!(host: room, answering_user_public_id: "@#{peer_agent.handle}")
    assert_predicate by_handle, :accepted?, by_handle.outcome.to_s
    assert_equal peer_agent, by_handle.value.answering_user
    assert_equal peer_agent.public_id,
      room.conversation_event_items.order(:sequence).last.payload.fetch("answering_user_public_id"),
      "the addressee rides `input_accepted` beside the author"

    by_id = create!(host: room, answering_user_public_id: peer_agent.public_id)
    assert_predicate by_id, :accepted?
    assert_equal peer_agent, by_id.value.answering_user

    assert_equal peer_agent, by_id.value.declaring_profile, "the addressee's declaration judges the row"
    assert_equal @user, create!.value.answering_user, "a Human's plain chat: the Human answers by default"
  end

  test "to: refuses an unknown name by name and an ineligible addressee as one" do
    room = room_answered_by(users(:agent))
    assert_equal :principal_unknown, create!(host: room, answering_user_public_id: "@nobody-here").outcome
    assert_equal :principal_unknown, create!(host: room, answering_user_public_id: SecureRandom.uuid_v7).outcome
    assert_equal :principal_unknown, create!(host: room, answering_user_public_id: users(:system).public_id).outcome,
      "the system user is never addressed"

    assert_equal :answerer_not_eligible, create!(host: room, answering_user_public_id: users(:owner).public_id).outcome,
      "a Human never answers a turn"
    reader = peer_agent
    room.conversation_access_entries.create!(user: reader, level: "read")
    assert_equal :answerer_not_eligible, create!(host: room, answering_user_public_id: reader.public_id).outcome,
      "read cannot answer: the addressee needs full on the row"
    room.conversation_access_entries.find_by!(user: reader).update!(level: "full")
    assert_predicate create!(host: room, answering_user_public_id: reader.public_id), :accepted?

    fenced = Conversation.create!(workspace: workspaces(:dedicated), creating_user: users(:agent))
    assert_equal :answerer_not_eligible,
      create!(host: fenced, acting_user: users(:owner), answering_user_public_id: reader.public_id).outcome,
      "the dedication fence: another agent cannot write in a dedicated home"
    assert_equal 0, room.conversation_inputs.where(answering_user: users(:owner)).count, "the refusals left no row"
  end

  test "the kernel's mail carries its loop's answerer on the one member and skips eligibility" do
    room = room_answered_by(users(:agent))
    room.conversation_access_entries.create!(user: peer_agent, level: "read")

    result = kernel_mail!(host: room, answering_user_public_id: peer_agent.public_id)
    assert_predicate result, :accepted?, "a receipt is never refused: the addressee is the mailing loop's own"
    assert_equal peer_agent, result.value.answering_user

    assert_equal users(:agent), kernel_mail!(host: room).value.answering_user, "unnamed mail: the conversation's"
  end

  test "the loop host refuses the addressee by name: a standalone loop answers as its creator" do
    agent_loop = AgentLoop.create!(workspace: @workspace, creating_user: @user, approval_mode: "bypass",
      status: "running")
    result = loop_input!(agent_loop, acting_user: @user, text: "go", answering_user_public_id: peer_agent.public_id)
    assert_equal :invalid, result.outcome
    assert result.record.errors.of_kind?(:answering_user_public_id, :not_admitted)

    accepted = loop_input!(agent_loop, acting_user: @user, text: "go")
    assert_equal @user, accepted.value.answering_user
  end

  # THE STEER CONJUNCT: a steer joins the reply in flight only when it names the answerer running it
  # — an UNNAMED steer addresses that running answerer (never the conversation's default past the
  # agent actually running), a named `to` that differs QUEUES.
  test "an unnamed steer addresses the running reply's answerer; a named other addressee queues" do
    room = room_answered_by(users(:agent))
    running = ConversationTurn.create!(
      account: @account, conversation: room, position: 0,
      kind: "direct_reply", role: "assistant", status: "running",
      speaker_actor: Actors::Resolve.member(account: @account, user: @user), control_owner_user: @user,
      answering_user: peer_agent
    )

    unnamed = create!(host: room, delivery_mode: "steer")
    assert_predicate unnamed, :accepted?
    assert_equal ["steering", running.id, peer_agent],
      [unnamed.value.state, unnamed.value.steering_target_turn_id, unnamed.value.answering_user],
      "the correction reaches the agent actually running, not the conversation's default"

    to_default = create!(host: room, delivery_mode: "steer", answering_user_public_id: users(:agent).public_id)
    assert_predicate to_default, :accepted?
    assert_equal ["pending", nil, users(:agent)],
      [to_default.value.state, to_default.value.steering_target_turn_id, to_default.value.answering_user],
      "another addressee's steer queues for its own turn — no refusal, nothing corrupts"

    to_running = create!(host: room, delivery_mode: "steer", answering_user_public_id: "@#{peer_agent.handle}")
    assert_equal ["steering", running.id], [to_running.value.state, to_running.value.steering_target_turn_id]
  end
  # ── the caller's clock ─────────────

  def drain_kicks = enqueued_jobs.select { |job| job[:job] == Conversations::Inputs::DrainJob }

  test "deliver_at is stored on the row, narrated, and the one kick is scheduled at the time" do
    at = 1.hour.from_now.change(usec: 0)

    result = nil
    assert_enqueued_jobs 1, only: Conversations::Inputs::DrainJob do
      result = create!(deliver_at: at)
    end

    assert_predicate result, :accepted?
    input = result.value
    assert_equal "pending", input.state
    assert_equal at, input.deliver_at
    kick = drain_kicks.sole
    assert_equal [@conversation.id], kick[:args]
    assert_equal at.to_f, kick[:at], "the receipt's own DrainJob, at the time it is due — no second kick"

    narration = @conversation.conversation_event_items.sole.payload
    assert_equal at.utc.iso8601, narration.fetch("deliver_at")

    plain = create!(entries: [{ "text" => "now" }])
    assert_nil plain.value.deliver_at
    assert_not @conversation.conversation_event_items.order(:sequence).last.payload.key?("deliver_at"),
      "an untimed row narrates no clock"
    assert_nil drain_kicks.last[:at], "an untimed row is kicked now"
  end

  # The references' agreed shape (decision 1): hermes refuses a one-shot
  # more than 120 s past, openclaw more than 60 s; inside the grace the row
  # is simply due and keeps the time it asked for. The far bound is
  # openclaw's ten years (decision 7) — a bound on a datetime that must
  # never reach the column, not a ceiling on work.
  test "inside the grace the row is stored and due now; beyond it deliver_at_in_past; ten years ahead deliver_at_too_far" do
    at = 1.minute.ago.change(usec: 0)
    result = create!(deliver_at: at)
    assert_predicate result, :accepted?
    assert_equal at, result.value.deliver_at, "keeps the time it asked for"
    assert_includes ConversationInput.due(Time.current).pluck(:id), result.value.id
    assert_nil drain_kicks.sole[:at], "a due row is kicked now, not at its past time"

    assert_equal :deliver_at_in_past, create!(deliver_at: 3.minutes.ago).outcome
    assert_equal :deliver_at_too_far, create!(deliver_at: 11.years.from_now).outcome
    assert_predicate create!(deliver_at: 9.years.from_now), :accepted?
    assert_equal 2, ConversationInput.count, "a refused time leaves no row"
    assert_equal 2, drain_kicks.length, "and no kick"
  end

  # A steer binds NOW to the reply in flight; a future steer has nothing
  # to bind to — refused by name before any binding is read, on an idle
  # room as on a busy one.
  test "a steer with a time refuses deliver_at_not_steerable, idle or in flight" do
    assert_equal :deliver_at_not_steerable, create!(delivery_mode: "steer", deliver_at: 1.hour.from_now).outcome

    build_running_turn
    assert_equal :deliver_at_not_steerable, create!(delivery_mode: "steer", deliver_at: 1.hour.from_now).outcome
    assert_equal 0, ConversationInput.count
    assert_empty drain_kicks
  end

  test "the loop door refuses deliver_at by name; kernel mail never carries one; a sent row may" do
    agent_loop = AgentLoop.create!(workspace: @workspace, creating_user: @user, approval_mode: "bypass",
      status: "running")
    result = loop_input!(agent_loop, acting_user: @user, text: "go", delivery_mode: "queue",
      deliver_at: 1.hour.from_now)
    assert_equal :invalid, result.outcome
    assert result.record.errors.of_kind?(:deliver_at, :not_admitted)

    assert_nil Conversations::Inputs::Create::Command.kernel(
      host: @conversation, acting_user: @user, entries: [{ "text" => "done" }],
      origin: ConversationInput::TASK_RESULT_ORIGIN, sender_conversation_public_id: @conversation.public_id
    ).deliver_at
    assert_raises(ArgumentError) do
      Conversations::Inputs::Create::Command.kernel(
        host: @conversation, acting_user: @user, entries: [{ "text" => "done" }],
        origin: ConversationInput::TASK_RESULT_ORIGIN, sender_conversation_public_id: @conversation.public_id,
        deliver_at: 1.hour.from_now
      )
    end

    at = 20.minutes.from_now.change(usec: 0)
    sent = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
      host: @conversation, acting_user: @user, entries: [{ "text" => "later" }],
      sender_conversation_public_id: SecureRandom.uuid_v7, deliver_at: at
    ))
    assert_predicate sent, :accepted?
    assert_equal at, sent.value.deliver_at
  end
end
