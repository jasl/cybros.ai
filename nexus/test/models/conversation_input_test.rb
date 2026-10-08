require "test_helper"

# The one input row, two hosts: every host answer the row reads is bitten here at the model level —
# kinds, the loop host's at-the-default block, `role`, the nil host, the steering target per host,
# the readonly host pair — on a conversation and on a standalone loop alike.
class ConversationInputTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    @actor = Speakers::Resolve.member(account: @account, user: @user)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
    @agent_run = AgentRun.create!(
      workspace: @workspace, creating_user: @user, status: "running", approval_mode: "bypass"
    )
  end

  def input(host:, **overrides)
    ConversationInput.new(**{
      account: @account, host: host, queue_position: 0, kind: "message",
      speaker: @actor, authoring_user: @user,
    }.merge(overrides))
  end

  def running_reply
    ConversationTurn.create!(
      account: @account, conversation: @conversation, position: 0,
      kind: "direct_reply", role: "assistant", status: "running",
      speaker: @actor, control_owner_user: @user
    )
  end

  test "each host admits its own kinds" do
    assert_predicate input(host: @conversation, kind: "direct_reply"), :valid?
    assert_predicate input(host: @agent_run, kind: "message"), :valid?

    reply = input(host: @agent_run, kind: "direct_reply")
    assert_not reply.valid?, "the loop is already replying"
    assert reply.errors.of_kind?(:kind, :inclusion)
  end

  test "only a held steer can upgrade its delivery timing" do
    row = input(host: @conversation, state: "steering", delivery_mode: "steer", steering_target_turn: running_reply)
    row.save!
    row.update!(delivery_mode: "steer_now")
    assert_not row.update(delivery_mode: "steer"), "send now cannot be withdrawn by changing its timing"
    assert row.errors.of_kind?(:delivery_mode, :invalid)

    queued = input(host: @conversation, delivery_mode: "queue", queue_position: 1)
    queued.save!
    assert_not queued.update(delivery_mode: "steer_now"), "a queued input never acquires a new binding by an edit"
    assert queued.errors.of_kind?(:delivery_mode, :invalid)
  end

  test "a record without a host adds errors and never raises" do
    orphan = ConversationInput.new(
      account: @account, queue_position: 0, kind: "message",
      speaker: @actor, authoring_user: @user
    )

    assert_not orphan.valid?
    assert orphan.errors.of_kind?(:host, :blank)
    assert orphan.errors.of_kind?(:kind, :inclusion), "no host means no admitted kind"
  end

  test "the loop host pins the assembly and fence fields at their defaults" do
    assert_predicate input(host: @agent_run), :valid?

    {
      provider_id: "dev", model_ref: "mock-text", reasoning_effort: "low",
      expected_context_revision: 3, expected_tail_turn_public_id: SecureRandom.uuid,
    }.each do |field, value|
      row = input(host: @agent_run, field => value)
      assert_not row.valid?, "#{field} has no meaning on a one-turn host"
      assert row.errors.of_kind?(field, :present), field.to_s
    end

    raw = input(host: @agent_run, kind: "message", context_mode: "raw")
    assert_not raw.valid?
    assert raw.errors.of_kind?(:context_mode, :inclusion)

    intents = input(host: @agent_run, context_options: { "history" => { "max_entries" => 1 } })
    assert_not intents.valid?
    assert intents.errors.of_kind?(:context_options, :present)

    configured = input(host: @agent_run, request_options: { "temperature" => 0.1 })
    assert_not configured.valid?
    assert configured.errors.of_kind?(:request_options, :present)

    hidden = input(host: @agent_run, visible_in_context: false)
    assert_not hidden.valid?
    assert hidden.errors.of_kind?(:visible_in_context, :inclusion)
  end

  # The turn's tool subset is the
  # declaring profile's set narrowed by NAME, never widened — a name the
  # profile does not declare is refused with that name on it.
  READ_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_file", "parameters" => { "type" => "object" } },
  }.freeze
  WRITE_TOOL = {
    "type" => "function",
    "function" => { "name" => "write_file", "parameters" => { "type" => "object" } },
  }.freeze

  def declare!(agent, tools, approval_mode: "bypass")
    outcome = Users::DeclareConfiguration.call(user: agent,
      tool_definitions: tools, approval_mode: approval_mode, approval_rules: nil, prompt_mechanism: nil,
      prompt_template: nil, compaction_policy: nil
    )
    assert_equal :declared, outcome.outcome
    agent
  end

  test "tool_names narrows the declaring profile's declaration by name and never adds" do
    agent = declare!(users(:agent), [READ_TOOL, WRITE_TOOL])
    # The Human's word on a conversation the agent ANSWERS: the names are judged against the
    # answerer's declaration, never the poster's.
    answered = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: agent)
    reply = ->(names) { input(host: answered, kind: "direct_reply", tool_names: names) }

    assert_predicate reply.(%w[read_file]), :valid?
    assert_predicate reply.(nil), :valid?, "nil is the whole declaration"

    guessed = reply.(%w[read_file compose])
    assert_not guessed.valid?, "a subset, never an addition"
    assert guessed.errors.of_kind?(:tool_names, :not_declared)
    assert_match(/compose/, guessed.errors.full_messages.to_sentence, "the offending name is named")

    orphan = input(host: @conversation, kind: "direct_reply", tool_names: %w[read_file])
    assert_not orphan.valid?, "a human's reply on a human's conversation declares nothing to narrow"
    assert orphan.errors.of_kind?(:tool_names, :not_declared)

    assert_predicate reply.([]), :valid?, "an empty list is NO TOOLS — a reply from context alone"

    [[""], %w[read_file read_file]].each do |names|
      row = reply.(names)
      assert_not row.valid?, "#{names.inspect} names no subset"
      assert row.errors.of_kind?(:tool_names, :invalid), names.inspect
    end
  end

  # THE TURN'S TIGHTENING: the declaring profile's word made stricter for one reply — bypass → ask →
  # rules — never looser; nil is the profile's own; a profile that declared no mode leaves nothing
  # to tighten.
  test "approval_mode tightens the declaring profile's mode and never loosens it" do
    agent = declare!(users(:agent), [READ_TOOL], approval_mode: "ask")
    answered = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: agent)
    reply = ->(mode) { input(host: answered, kind: "direct_reply", approval_mode: mode) }

    assert_predicate reply.(nil), :valid?, "nil is the profile's word"
    assert_predicate reply.("ask"), :valid?, "rank-equal is lawful"
    assert_predicate reply.("rules"), :valid?

    loosened = reply.("bypass")
    assert_not loosened.valid?
    assert loosened.errors.of_kind?(:approval_mode, :not_tightening)
    assert_match(/bypass → ask → rules/, loosened.errors.full_messages.to_sentence)

    unknown = reply.("always")
    assert_not unknown.valid?
    assert unknown.errors.of_kind?(:approval_mode, :inclusion)

    orphan = input(host: @conversation, kind: "direct_reply", approval_mode: "ask")
    assert_not orphan.valid?, "a human's reply on a human's conversation declares nothing to tighten"
    assert orphan.errors.of_kind?(:approval_mode, :not_tightening)

    message = input(host: @conversation, kind: "message", authoring_user: agent, approval_mode: "ask")
    assert_not message.valid?, "a message compiles no request"
    assert message.errors.of_kind?(:approval_mode, :invalid)

    on_loop = input(host: @agent_run, authoring_user: agent, approval_mode: "ask")
    assert_not on_loop.valid?, "the loop's one turn carries its shell's word"
    assert on_loop.errors.of_kind?(:approval_mode, :present)
  end

  test "tool_names belongs to the reply lane on a conversation host" do
    agent = declare!(users(:agent), [READ_TOOL])

    message = input(host: @conversation, kind: "message", authoring_user: agent,
      tool_names: %w[read_file])
    assert_not message.valid?, "a message compiles no request"
    assert message.errors.of_kind?(:tool_names, :invalid)

    on_loop = input(host: @agent_run, authoring_user: agent, tool_names: %w[read_file])
    assert_not on_loop.valid?, "the loop's one turn carries its seed's tools"
    assert on_loop.errors.of_kind?(:tool_names, :present)
  end

  test "the conversation host takes the same fields freely" do
    row = input(host: @conversation, kind: "direct_reply", provider_id: "dev",
      model_ref: "mock-text", reasoning_effort: "low", visible_in_context: false,
      request_options: { "temperature" => 0.1 },
      context_options: { "history" => { "max_entries" => 1 } },
      expected_context_revision: 0)

    assert_predicate row, :valid?
  end

  test "role is user only when steering, and always on a loop host" do
    turn = running_reply

    queued = input(host: @conversation, role: "assistant")
    assert_predicate queued, :valid?, "a queued row may carry any role on a conversation"

    steering = input(host: @conversation, role: "assistant",
      state: "steering", steering_target_turn: turn)
    assert_not steering.valid?, "a bound steer renders as the person's trailing message"
    assert steering.errors.of_kind?(:role, :inclusion)

    loop_system = input(host: @agent_run, role: "system")
    assert_not loop_system.valid?, "every loop-host input drains as a user message"
    assert loop_system.errors.of_kind?(:role, :inclusion)
    assert_predicate input(host: @agent_run, role: "user"), :valid?
  end

  test "a bound steer names its turn on a conversation and no turn on a loop" do
    turn = running_reply

    unbound = input(host: @conversation, state: "steering")
    assert_not unbound.valid?
    assert unbound.errors.of_kind?(:steering_target_turn, :blank)
    assert_predicate input(host: @conversation, state: "steering", steering_target_turn: turn), :valid?

    assert_predicate input(host: @agent_run, state: "steering"), :valid?,
      "the loop IS its one turn-shaped unit"
    targeted = input(host: @agent_run, state: "steering", steering_target_turn: turn)
    assert_not targeted.valid?
    assert targeted.errors.of_kind?(:steering_target_turn, :present)
  end

  test "the host's refusal lands on the row at create" do
    @agent_run.update!(status: "completed")
    settled = input(host: @agent_run)
    assert_not settled.valid?
    assert settled.errors.of_kind?(:host, :run_settled)

    @agent_run.update!(status: "canceling")
    assert_not input(host: @agent_run).valid?, "a dying loop has no next boundary either"

    @agent_run.update!(status: "running", tombstoned_at: Time.current)
    gone = input(host: @agent_run)
    assert_not gone.valid?
    assert gone.errors.of_kind?(:host, :not_found)

    hosted = create_run_backed_turn(conversation: @conversation, acting_user: @user)
    through_the_loop = input(host: hosted.agent_run)
    assert_not through_the_loop.valid?, "a loop-backed loop's door is its conversation's"
    assert through_the_loop.errors.of_kind?(:host, :conversation_hosted)
  end

  test "the account derives from the host, and the host pair is creation-frozen" do
    row = input(host: @agent_run, account: nil)
    row.save!
    assert_equal @account.id, row.account_id

    other = Conversation.create!(workspace: @workspace, creating_user: @user)
    assert_raises(ActiveRecord::ReadonlyAttributeError) { row.update!(host: other) }
    assert_equal @agent_run, row.reload.host
  end

  # ONE declaring-profile rule, on the hosts: the HOST's answerer when it is an agent — a
  # conversation's stored answerer, a standalone loop's creator — resolved onto the row's own
  # addressee column as the door resolves it, at validation. The input's author is only the speaker.
  test "the declaring profile is the host's answerer; the author is only the speaker" do
    agent = users(:agent)
    assert_nil @agent_run.declaring_profile, "a Human-created standalone loop declares nothing"
    assert_equal @user, @agent_run.answering_user, "a standalone loop answers as its creator"
    assert_nil @conversation.declaring_profile
    assert_nil input(host: @conversation, authoring_user: agent).tap(&:validate).declaring_profile,
      "an agent posting into a Human-answered conversation does not bring its engine"

    by_agent = AgentRun.create!(workspace: @workspace, creating_user: agent, status: "running", approval_mode: "bypass")
    assert_equal agent, by_agent.declaring_profile
    assert_equal agent, input(host: by_agent).tap(&:validate).declaring_profile, "a Human's input on the agent's loop"

    answered = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: agent)
    assert_equal agent, input(host: answered).tap(&:validate).declaring_profile,
      "a Human's word on a conversation answered by an agent declares through the answerer"
    hosted = create_run_backed_turn(conversation: answered, acting_user: @user)
    assert_equal @user, hosted.agent_run.creating_user, "the backing loop's creator is the speaker"
    assert_equal agent, hosted.agent_run.answering_user, "a loop-backed loop answers as its conversation does"
    assert_equal agent, hosted.agent_run.declaring_profile,
      "a loop-backed loop's declaring profile is its conversation's answerer"
  end

  test "the steering finders read the host's rows" do
    turn = running_reply
    bound = input(host: @conversation, state: "steering", steering_target_turn: turn)
    bound.save!
    loop_bound = input(host: @agent_run, state: "steering")
    loop_bound.save!
    input(host: @agent_run, queue_position: 1).save!

    assert_equal [bound], @conversation.conversation_inputs.steering.to_a
    assert_equal [loop_bound], @agent_run.conversation_inputs.steering.to_a
    assert_equal 1, @agent_run.follow_up_inputs.count
  end

  # THE INLINE SLOT OVERRIDE: `slot` xor `position`; `role` optional beside a slot (the block takes
  # the registered document's, else `system`), required without one; the slot is a closed word.
  test "an inline entry names a slot or a position, never both, and a slot needs no role" do
    reply = ->(entries) { input(host: @conversation, kind: "direct_reply", context_options: { "inline" => entries }) }

    assert_predicate reply.call([{ "slot" => "character", "text" => "the room" }]), :valid?
    assert_predicate reply.call([{ "slot" => "persona", "role" => "user", "text" => "the person" }]), :valid?
    assert_predicate reply.call([{ "role" => "developer", "position" => "lead", "text" => "x" }]), :valid?

    both = reply.call([{ "slot" => "character", "position" => "lead", "text" => "x" }])
    assert_not both.valid?, "slot and position together"
    assert both.errors.of_kind?(:context_options, :invalid)
    assert_not reply.call([{ "slot" => "mood", "text" => "x" }]).valid?, "a stranger slot"
    assert_not reply.call([{ "slot" => "character", "role" => "tool", "text" => "x" }]).valid?, "a stranger role"
    assert_not reply.call([{ "position" => "lead", "text" => "x" }]).valid?, "no slot: role is required"
    assert_not reply.call([{ "slot" => "character", "text" => "" }]).valid?, "empty text"
  end

  # THE OVERRIDE IS MACRO-VALIDATED LIKE THE SLOT IT REPLACES: an inline slot entry is rendered by
  # the same registry the slot door validates against, so a word outside it is refused here by name
  # — the sibling door must not let through what the slot door refuses. A positioned entry is the
  # client's literal text and keeps its braces.
  test "an inline slot override naming an unknown macro is refused by the macro's word" do
    reply = ->(entries) { input(host: @conversation, kind: "direct_reply", context_options: { "inline" => entries }) }

    assert_predicate reply.call([{ "slot" => "character", "text" => "Today is {{date}} with {{user}}." }]), :valid?
    assert_predicate reply.call([{ "role" => "developer", "position" => "lead", "text" => "{{mood}} stays literal" }]),
      :valid?

    unknown = reply.call([{ "slot" => "character", "text" => "The room is {{ mood }}." }])
    assert_not unknown.valid?
    assert_equal [{ error: :macro_unknown, name: "mood" }], unknown.errors.details[:context_options]
    assert_match(/\{\{mood\}\}/, unknown.errors.full_messages.first)
  end

  # THE TURN'S VARIABLES: admitted only where something compiles them — an addressee whose standing
  # word is `assembly` — closed to the names its template declares, string values. An intent nothing
  # would read is invalid, never a silent drop.
  test "variables ride only to an assembly addressee, and only the declared names" do
    agent = users(:agent)
    template = { "blocks" => [{ "type" => "lead" }, { "type" => "history" }, { "type" => "input" }],
                 "variables" => { "scene" => "dusk" } }
    reply = ->(**fields) { input(host: @conversation, kind: "direct_reply", answering_user: agent, **fields) }

    declare_mechanism!(agent, "default", template)
    unread = reply.call(context_options: { "variables" => { "scene" => "dawn" } })
    assert_not unread.valid?, "a default addressee compiles no variable"
    assert unread.errors.of_kind?(:context_options, :invalid)

    declare_mechanism!(agent, "assembly", template)
    assert_predicate reply.call(context_options: { "variables" => { "scene" => "dawn" } }), :valid?
    assert_predicate reply.call(context_options: { "variables" => {} }), :valid?, "no value: the defaults"

    undeclared = reply.call(context_options: { "variables" => { "mood" => "calm" } })
    assert_not undeclared.valid?
    assert_equal [{ error: :variable_undeclared, name: "mood" }], undeclared.errors.details[:context_options]

    assert_not reply.call(context_options: { "variables" => { "scene" => 3 } }).valid?, "a value is a string"
    assert_not reply.call(context_options: { "variables" => "scene=dawn" }).valid?
    assert_not reply.call(context_options: { "variables" => { "scene" => nil } }).valid?

    human_addressed = input(host: @conversation, kind: "direct_reply", answering_user: @user,
      context_options: { "variables" => { "scene" => "dawn" } })
    assert_not human_addressed.valid?, "a Human addressee has no template"
  end

  test "a positioned inline entry needs the addressee's template to place it" do
    agent = users(:agent)
    declare_mechanism!(agent, "assembly",
      { "blocks" => [{ "type" => "lead" }, { "type" => "history" }, { "type" => "input" }] })
    reply = ->(entries) { input(host: @conversation, kind: "direct_reply", answering_user: agent, context_options: { "inline" => entries }) }

    assert_predicate reply.call([{ "role" => "user", "text" => "l" }]), :valid?, "no position is the lead"
    assert_predicate reply.call([{ "role" => "user", "text" => "l", "position" => "lead" }]), :valid?
    unplaced = reply.call([{ "role" => "user", "text" => "t", "position" => "tail" }])
    assert_not unplaced.valid?
    assert_equal [{ error: :inline_position_unplaced, position: "tail" }], unplaced.errors.details[:context_options]

    declare_mechanism!(agent, "default", nil)
    assert_predicate reply.call([{ "role" => "user", "text" => "t", "position" => "tail" }]), :valid?,
      "the built-in order places both"
  end

  # A positioned entry rides the turn's preface into history, behind earlier turns: a `system`
  # entry there would be a mid-conversation system message the wires hoist to byte one, and an
  # `assistant` one words the model never said. A slot override keeps its system role.
  test "a positioned inline entry is user or developer; system and assistant refuse inline_role_unplaced" do
    agent = users(:agent)
    reply = ->(entries) { input(host: @conversation, kind: "direct_reply", answering_user: agent, context_options: { "inline" => entries }) }

    %w[system assistant].each do |role|
      [nil, "lead", "tail"].each do |position|
        entry = { "role" => role, "text" => "t", "position" => position }.compact
        refused = reply.call([entry])
        assert_not refused.valid?, entry.inspect
        assert_equal [{ error: :inline_role_unplaced, role: role }], refused.errors.details[:context_options]
      end
    end
    assert_predicate reply.call([{ "role" => "developer", "text" => "d" }, { "role" => "user", "text" => "u", "position" => "tail" }]),
      :valid?
    assert_predicate reply.call([{ "slot" => "persona", "role" => "system", "text" => "P" }]), :valid?,
      "a slot override keeps system"
  end

  test "a system_prompt override sees the addressee's declared variables; the other slots see the four sources" do
    agent = users(:agent)
    declare_mechanism!(agent, "assembly",
      { "blocks" => [{ "type" => "slot", "slot" => "system_prompt" }, { "type" => "history" }, { "type" => "input" }],
        "variables" => { "scene" => "dusk" } })
    reply = ->(entries) { input(host: @conversation, kind: "direct_reply", answering_user: agent, context_options: { "inline" => entries }) }

    assert_predicate reply.call([{ "slot" => "system_prompt", "text" => "Scene {{scene}}" }]), :valid?
    other = reply.call([{ "slot" => "character", "text" => "Scene {{scene}}" }])
    assert_not other.valid?
    assert_equal [{ error: :macro_unknown, name: "scene" }], other.errors.details[:context_options]
  end

  def declare_mechanism!(agent, mechanism, template)
    outcome = Users::DeclareConfiguration.call(user: agent,
      tool_definitions: [], approval_mode: nil, approval_rules: nil, prompt_mechanism: mechanism,
      prompt_template: template, compaction_policy: nil
    )
    assert_equal :declared, outcome.outcome, outcome.user.errors.full_messages.join
  end

  # `raw`'s system field: present only on a raw direct reply — refused on an assembled input, on a
  # message, and on the loop host.
  test "instructions belong to raw on the reply lane alone" do
    assert_predicate input(host: @conversation, kind: "direct_reply", context_mode: "raw",
      instructions: "Be brief."), :valid?

    assembled = input(host: @conversation, kind: "direct_reply", instructions: "Be brief.")
    assert_not assembled.valid?
    assert assembled.errors.of_kind?(:instructions, :invalid)

    message = input(host: @conversation, kind: "message", instructions: "Be brief.")
    assert_not message.valid?
    assert message.errors.of_kind?(:instructions, :invalid)

    hosted = input(host: @agent_run, kind: "message", instructions: "Be brief.")
    assert_not hosted.valid?
    assert hosted.errors.of_kind?(:instructions, :present)
  end

  # THE READ ORDER: the KERNEL'S SET first, then arrival — a read rule over `queue_position`, never
  # a renumbering. An agent's `send` is a peer's word: it reads in arrival order like a person's and
  # COUNTS against the bound; only `task_result` and `child` lead and go uncounted.
  test "in_read_order puts the kernel set first then arrival; caller_authored counts person and agent" do
    first = input(host: @conversation, queue_position: 0).tap(&:save!)
    receipt = input(host: @conversation, queue_position: 1, origin: ConversationInput::TASK_RESULT_ORIGIN,
      sender_conversation_public_id: @conversation.public_id).tap(&:save!)
    sent = input(host: @conversation, queue_position: 2, origin: "agent",
      sender_conversation_public_id: @conversation.public_id).tap(&:save!)
    child = input(host: @conversation, queue_position: 3, origin: ConversationInput::CHILD_ORIGIN,
      sender_conversation_public_id: @conversation.public_id).tap(&:save!)
    second = input(host: @conversation, queue_position: 4).tap(&:save!)

    assert_equal [receipt, child, first, sent, second], @conversation.conversation_inputs.in_read_order.to_a
    assert_equal [first, sent, second],
      @conversation.conversation_inputs.caller_authored.order(:queue_position).to_a
    assert_equal [0, 1, 2, 3, 4], [first, receipt, sent, child, second].map { |row| row.reload.queue_position },
      "the order is read, not written"
  end

  # THE VOCABULARY: `origin` is the source kind of every row, closed at four words. A row derives
  # its own word from its author's kind — `person` for a human, `agent` for an agent — and a
  # writer's explicit word (the kernel's `task_result`/`child`) wins. `m1`: the API says `person`
  # where `users.kind` says `human`; neither is fixed.
  test "origin is derived from the author's kind, closed at four words, and the kernel set is two of them" do
    assert_equal %w[person agent task_result child], ConversationInput::ORIGINS
    assert_equal %w[task_result child], ConversationInput::KERNEL_ORIGINS

    person = input(host: @conversation)
    assert_predicate person, :valid?
    assert_equal "person", person.origin
    assert_predicate person, :origin_person?
    assert_not person.kernel_origin?

    agent_user = users(:agent)
    agent_row = input(host: @conversation, authoring_user: agent_user,
      speaker: Speakers::Resolve.member(account: @account, user: agent_user))
    assert_predicate agent_row, :valid?
    assert_equal "agent", agent_row.origin
    assert_not agent_row.kernel_origin?, "a principal's word, whatever its kind"

    child = input(host: @conversation, origin: ConversationInput::CHILD_ORIGIN,
      sender_conversation_public_id: @conversation.public_id)
    assert_predicate child, :valid?
    assert_predicate child, :kernel_origin?
    assert_predicate child, :origin_child?
    assert_predicate input(host: @conversation, origin: ConversationInput::TASK_RESULT_ORIGIN,
      sender_conversation_public_id: @conversation.public_id), :kernel_origin?

    stranger = input(host: @conversation, origin: "kernel")
    assert_not stranger.valid?, "a word outside the vocabulary is refused, never stored"
    assert stranger.errors.of_kind?(:origin, :inclusion)
  end

  # THE ADDRESSEE: one column on the row, resolved at the door and defaulting to the host's answerer
  # — a conversation's stored one, a standalone loop's creator — so no reader branches on nil; the
  # two per-turn validations and `raw?` judge the ADDRESSEE's declaration, never the conversation's
  # default; create-frozen like the author pair.
  test "the addressee defaults to the host's answerer and is frozen at create" do
    agent = users(:agent)
    answered = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: agent)

    assert_equal @user, input(host: @conversation).tap(&:validate).answering_user, "a Human's conversation"
    assert_equal agent, input(host: answered).tap(&:validate).answering_user, "the stored answerer"
    assert_equal @user, input(host: @agent_run).tap(&:validate).answering_user, "a standalone loop's creator"

    row = input(host: answered, answering_user: @user)
    row.save!
    assert_equal @user, row.reload.answering_user, "the door's word, not the default"
    assert_raises(ActiveRecord::ReadonlyAttributeError) { row.update!(answering_user: agent) }
  end

  test "the declaring profile and its two validations follow the addressee" do
    agent = users(:agent)
    outcome = Users::DeclareConfiguration.call(user: agent,
      tool_definitions: [{ "type" => "function", "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } }],
      approval_mode: "ask", approval_rules: nil, prompt_mechanism: nil, prompt_template: nil, compaction_policy: nil
    )
    assert_equal :declared, outcome.outcome

    to_agent = input(host: @conversation, kind: "direct_reply", answering_user: agent, tool_names: ["read_file"],
      approval_mode: "rules")
    assert_equal agent, to_agent.declaring_profile, "a Human's conversation, an agent addressed"
    assert_predicate to_agent, :valid?

    to_human = input(host: @conversation, kind: "direct_reply", answering_user: @user, tool_names: ["read_file"])
    assert_nil to_human.declaring_profile
    assert_not to_human.valid?
    assert to_human.errors.of_kind?(:tool_names, :not_declared), "the Human addressee declares nothing"
  end
  # ── the caller's clock on the row ──

  test "deliver_at is a door field of the conversation host alone, and the loop host's row refuses it" do
    assert_includes ConversationInput::DOOR_FIELDS, :deliver_at
    assert_not_includes AgentRun::ADMITTED_INPUT_FIELDS, :deliver_at

    assert_predicate input(host: @conversation, deliver_at: 1.hour.from_now), :valid?
    timed = input(host: @agent_run, deliver_at: 1.hour.from_now)
    assert_not timed.valid?, "a loop's one turn is in flight: nothing waits behind it"
    assert timed.errors.of_kind?(:deliver_at, :present)
  end

  # DUE: nothing scheduled, or scheduled for a time that has passed — the
  # explicit OR, as the admitter spells its own; a row before its time is
  # not in the room yet.
  test "due(now) reads the untimed row and the passed one; a row before its time is not in the room" do
    now = Time.current
    untimed = input(host: @conversation, queue_position: 0).tap(&:save!)
    passed = input(host: @conversation, queue_position: 1, deliver_at: now - 1).tap(&:save!)
    exact = input(host: @conversation, queue_position: 2, deliver_at: now).tap(&:save!)
    ahead = input(host: @conversation, queue_position: 3, deliver_at: now + 1).tap(&:save!)

    due = @conversation.conversation_inputs.merge(ConversationInput.due(now)).order(:queue_position).pluck(:id)
    assert_equal [untimed.id, passed.id, exact.id], due
    assert_not_includes due, ahead.id
  end
end
