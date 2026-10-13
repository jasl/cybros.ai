require "test_helper"

# The binding is readable on the host: `runner` on the full document — the executor, its name, its
# presence and contact sample — nil before any binding and nil after a reap (the FK nullifies).
# Never on the listing shape.
class AgentAPI::ConversationPresenterTest < ActiveSupport::TestCase
  include RunSeamTestHelper

  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
    @runner = connect_runner(manager: users(:owner), registration_identifier: "r", display_name: "Laptop",
      assignment_scope: :account_wide).executor_access_token.task_executor
  end

  # The answering profile is readable on both shapes: the listing says who answers, a scalar off one
  # preloaded association.
  test "answering_user_public_id rides basic, so the listings too" do
    mine = Conversation.create!(workspace: @workspace, creating_user: @human)
    assert_equal @human.public_id, AgentAPI::ConversationPresenter.basic(mine).fetch(:answering_user_public_id)

    answered = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent))
    assert_equal users(:agent).public_id, AgentAPI::ConversationPresenter.basic(answered).fetch(:answering_user_public_id)
    assert_equal users(:agent).public_id, AgentAPI::ConversationPresenter.full(answered, acting_user: @human).fetch(:answering_user_public_id)
  end

  # A side conversation is a child row a UI may hide: `side` rides basic so the listings can, and
  # the working list's `?side=1` is the one way to see them.
  test "side rides basic as a boolean on every row" do
    plain = Conversation.create!(workspace: @workspace, creating_user: @human)
    assert_equal false, AgentAPI::ConversationPresenter.basic(plain).fetch(:side)

    side = Conversation.create!(workspace: @workspace, creating_user: @human, side: true)
    assert_equal true, AgentAPI::ConversationPresenter.basic(side).fetch(:side)
    assert_equal true, AgentAPI::ConversationPresenter.full(side, acting_user: @human).fetch(:side)
  end

  # THE PARENT FACTS: a spawned child names its parent, the `spawn` call that minted it and its
  # label as ONE block on basic — the `/children` listing prints them — nil on a top-level row. The
  # call's key is the id the spawning model read back; it goes nil with the spawning loop's reap
  # while the parent's id survives.
  test "parent rides basic as one block: the parent's id, the spawn call's key, the label" do
    agent = users(:agent)
    root = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: agent)
    assert_nil AgentAPI::ConversationPresenter.basic(root).fetch(:parent)
    assert_nil AgentAPI::ConversationPresenter.full(root, acting_user: @human).fetch(:parent)

    seam = create_run_backed_turn(conversation: root, acting_user: @human)
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: seam.agent_run, origin: "model",
      steps: [AgentRuns::Tasks::Step::Tool.new(key: "r1t0", name: "spawn", input: { "prompt" => "review" })],
      tip: AgentRuns::Tasks::Tip.seed(AgentRuns::Tasks::Compile::BRANCH)
    ))
    assert_predicate appended, :applied?
    call = seam.agent_run.agent_run_tasks.find_by!(node_key: "r1t0")
    child = Conversation.create!(workspace: @workspace, creating_user: agent, answering_user: agent,
      parent_conversation: root, parent_conversation_public_id: root.public_id,
      spawn_node: call, spawn_label: "Reviewer")

    assert_equal({ public_id: root.public_id, spawn_node_key: "r1t0", label: "reviewer" },
      AgentAPI::ConversationPresenter.basic(child).fetch(:parent))
    assert_equal({ public_id: root.public_id, spawn_node_key: "r1t0", label: "reviewer" },
      AgentAPI::ConversationPresenter.full(child, acting_user: @human).fetch(:parent))
    assert_not AgentAPI::ConversationPresenter.basic(child).key?(:parent_conversation_public_id),
      "one block, never a second flat spelling"

    Conversation.where(id: child.id).update_all(spawn_node_id: nil)
    assert_equal({ public_id: root.public_id, spawn_node_key: nil, label: "reviewer" },
      AgentAPI::ConversationPresenter.basic(child.reload).fetch(:parent), "a reaped call leaves the parent named")
  end

  test "runner carries the four keys when bound, nil when unbound, and vanishes with a reaped executor" do
    NexusServer.register
    unbound = Conversation.create!(workspace: @workspace, creating_user: @human)
    assert_nil AgentAPI::ConversationPresenter.full(unbound, acting_user: @human).fetch(:default_runner)
    assert_not AgentAPI::ConversationPresenter.basic(unbound).key?(:runner)

    bound = Conversation.create!(workspace: @workspace, creating_user: @human, default_runner_executor: @runner)
    @runner.update!(last_seen_at: 1.minute.ago)
    @runner.mark_connected("socket-1")
    assert_equal(
      { executor_public_id: @runner.public_id, display_name: "Laptop", presence: "online",
        last_seen_at: @runner.reload.last_seen_at },
      AgentAPI::ConversationPresenter.full(bound.reload, acting_user: @human).fetch(:default_runner)
    )

    # The reap nullifies the FK (schema: on_delete nullify) — the same
    # column state, written directly.
    bound.update_columns(default_runner_executor_id: nil)
    assert_nil AgentAPI::ConversationPresenter.full(bound.reload, acting_user: @human)[:default_runner]
  end

  # THE ACCESS CARRIER: the default and the entries ride `full` only, like `runner`; each entry is
  # self-describing (the member plane has no user listing, so this is the first place it prints
  # another User's `display_name`). The creator and the answerer are derived and never appear as
  # rows.
  test "access rides full with the default and the self-describing entries, never basic" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
      answering_user: users(:agent), access_default: "none")
    conversation.conversation_access_entries.create!(user: users(:owner), level: "read")
    conversation.conversation_access_entries.create!(user: users(:curator), level: "full")

    access = AgentAPI::ConversationPresenter.full(conversation, acting_user: @human).fetch(:access)

    assert_equal "none", access.fetch(:default)
    assert_equal [
      { user_public_id: users(:owner).public_id, handle: "owner", kind: "human", display_name: "Owner", level: "read" },
      { user_public_id: users(:curator).public_id, handle: "curator", kind: "human", display_name: "Curator",
        level: "full" },
    ], access.fetch(:entries), "entries in insertion order; the creator and the answerer are derived, not rows"
    assert_not AgentAPI::ConversationPresenter.basic(conversation).key?(:access)

    bare = Conversation.create!(workspace: @workspace, creating_user: @human)
    assert_equal({ default: "full", entries: [] }, AgentAPI::ConversationPresenter.full(bare, acting_user: @human).fetch(:access),
      "never nil: an empty set under the birth default")
  end

  # WHO SPOKE AND WHO ANSWERS: every input and every turn carries its addressee's id, and a
  # `speaker` block — the VOICE the renderer reads: a row's author, a message turn's speaker, a
  # reply turn's ANSWERER — self-describing as an access entry is. The kernel's own summary turn has
  # no principal to name.
  test "speaker and answering_user_public_id ride every input and turn" do
    agent = users(:agent)
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    actor = Speakers::Resolve.member(account: conversation.account, user: @human)
    input = conversation.conversation_inputs.create!(
      account: conversation.account, queue_position: 0, kind: "direct_reply", role: "user",
      state: "pending", delivery_mode: "queue", speaker: actor, authoring_user: @human,
      answering_user: agent
    )
    projected = AgentAPI::ConversationPresenter.input(input)
    assert_equal agent.public_id, projected.fetch(:answering_user_public_id)
    assert_equal({ user_public_id: @human.public_id, handle: "member", kind: "human", display_name: @human.display_name },
      projected.fetch(:speaker), "the row's author")

    message = ConversationTurn.create!(account: conversation.account, conversation: conversation, position: 0,
      kind: "message", role: "user", status: "completed", speaker: actor, control_owner_user: @human)
    reply = ConversationTurn.create!(account: conversation.account, conversation: conversation, position: 1,
      kind: "direct_reply", role: "assistant", status: "completed", speaker: actor,
      control_owner_user: @human, answering_user: agent)
    summary = ConversationTurn.create!(account: conversation.account, conversation: conversation, position: 2,
      kind: "compaction_summary", role: "user", status: "completed",
      speaker: Speakers::Resolve.system(account: conversation.account), control_owner_user: @human)

    blocks = [message, reply, summary].map { |turn| AgentAPI::ConversationPresenter.turn_snapshot(turn) }
    assert_equal [@human.public_id, agent.public_id, @human.public_id],
      blocks.map { |block| block.fetch(:answering_user_public_id) },
      "the conversation's answerer on a message and on the kernel's summary, the addressee on a reply"
    assert_equal [
      { user_public_id: @human.public_id, handle: "member", kind: "human", display_name: @human.display_name },
      { user_public_id: agent.public_id, handle: "fixture-agent", kind: "agent", display_name: agent.display_name },
    ], blocks.first(2).map { |block| block.fetch(:speaker) },
      "a message turn's speaker, a reply turn's answerer"
    assert_not blocks.last.key?(:speaker), "the kernel's summary names no principal"
  end

  # THE PERSON'S WORDS ON A REPLY TURN: every `say` materializes ONE `direct_reply` turn whose seed
  # lives on the variant's `prompt` body, so `prompt_text` is that body's readable text on the
  # variant block, beside the reply's `content` — absent on a message turn (its `content` IS the
  # person's words) and on a seed carrying no text (a picture alone): read by presence, so every
  # older pin stays byte-stable.
  test "prompt_text rides a reply turn's variant, never a message turn's nor a wordless seed's" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    actor = Speakers::Resolve.member(account: conversation.account, user: @human)
    message = settled_turn!(conversation, actor, position: 0, kind: "message", role: "user", content: "hello there")
    reply = settled_turn!(conversation, actor, position: 1, kind: "direct_reply", role: "assistant",
      content: "the reply", prompt: { entries: [{ "text" => "what is next?" }], readable_text: "what is next?" })
    picture = conversation.account.content_uploads.create!(
      creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(PNG), filename: "seed.png", content_type: "image/png", identify: false
      )
    )
    wordless = settled_turn!(conversation, actor, position: 2, kind: "direct_reply", role: "assistant",
      content: "seen",
      prompt: { entries: [{ "role" => "user",
                            "parts" => [{ "type" => "upload", "upload_public_id" => picture.public_id }] }],
                uploads: [picture], readable_text: "" })

    blocks = [message, reply, wordless].map do |turn|
      AgentAPI::ConversationPresenter.turn_snapshot(turn).fetch(:active_variant)
    end
    assert_equal "what is next?", blocks[1].fetch(:prompt_text), "the seed's words, beside the reply's content"
    assert_equal "the reply", blocks[1].fetch(:content)
    assert_equal "hello there", blocks[0].fetch(:content)
    assert_not blocks[0].key?(:prompt_text), "a message turn's content IS the person's words"
    assert_not blocks[2].key?(:prompt_text), "a picture-only seed carries no words: absent, never \"\""
    assert_equal [picture.public_id], blocks[2].fetch(:attachments).map { |row| row.fetch(:public_id) },
      "the wordless seed still shows its picture"
  end

  # THE DECK'S SEAM: `variant(prompt:)` renders the block the turns page renders — `prompt_text` by
  # presence off the `prompt` body a door hands — so no deck door reads a reply turn's seed its own
  # way; a door handing none renders none, a wordless seed renders none.
  test "variant(prompt:) renders prompt_text by presence: the seed's words, absent unhanded or wordless" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    actor = Speakers::Resolve.member(account: conversation.account, user: @human)
    reply = settled_turn!(conversation, actor, position: 0, kind: "direct_reply", role: "assistant",
      content: "the reply", prompt: { entries: [{ "text" => "what is next?" }], readable_text: "what is next?" })
    picture = conversation.account.content_uploads.create!(
      creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(PNG), filename: "seed.png", content_type: "image/png", identify: false
      )
    )
    wordless = settled_turn!(conversation, actor, position: 1, kind: "direct_reply", role: "assistant",
      content: "seen",
      prompt: { entries: [{ "role" => "user",
                            "parts" => [{ "type" => "upload", "upload_public_id" => picture.public_id }] }],
                uploads: [picture], readable_text: "" })
    bodies = reply.active_variant.content_bodies.index_by(&:role)

    worded = AgentAPI::ConversationPresenter.variant(reply.active_variant, body: bodies["content"], active: true,
      prompt: bodies["prompt"])
    assert_equal "what is next?", worded.fetch(:prompt_text), "the seed's words, beside the reply's content"
    assert_equal "the reply", worded.fetch(:content)
    assert_equal AgentAPI::ConversationPresenter.turn_snapshot(reply).fetch(:active_variant),
      worded.except(:active), "the deck's block IS the turns page's block"

    unhanded = AgentAPI::ConversationPresenter.variant(reply.active_variant, body: bodies["content"], active: true)
    assert_not unhanded.key?(:prompt_text), "a door that hands no prompt body renders no prompt_text"
    assert_not unhanded.key?(:attachments)

    wordless_bodies = wordless.active_variant.content_bodies.index_by(&:role)
    pictured = AgentAPI::ConversationPresenter.variant(wordless.active_variant, body: wordless_bodies["content"],
      active: false, prompt: wordless_bodies["prompt"])
    assert_not pictured.key?(:prompt_text), "a picture-only seed carries no words: absent, never \"\""
    assert_equal [picture.public_id], pictured.fetch(:attachments).map { |row| row.fetch(:public_id) },
      "the wordless seed's picture rides the deck as it rides the turns page"
    assert_equal false, pictured.fetch(:active)
  end

  test "variants expose their frozen memory context including null and disabled roots" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
      memory_context: { "bindings" => [] })
    actor = Speakers::Resolve.member(account: conversation.account, user: @human)
    bound = { "bindings" => [
      { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
      { "name" => "group", "scope" => "conversation", "access" => "read",
        "conversation_public_id" => conversation.public_id },
    ] }

    [nil, bound, { "bindings" => [] }].each_with_index do |memory_context, position|
      turn = settled_turn!(conversation, actor, position: position, kind: "direct_reply", role: "assistant",
        content: "the reply", memory_context: memory_context)
      snapshot = AgentAPI::ConversationPresenter.turn_snapshot(turn).fetch(:active_variant)
      deck = AgentAPI::ConversationPresenter.variant(turn.active_variant, body: nil, active: true)

      assert_equal({ memory_context: memory_context }, snapshot.slice(:memory_context))
      assert_equal({ memory_context: memory_context }, deck.slice(:memory_context))
    end

    assert_equal({ "bindings" => [] }, AgentAPI::ConversationPresenter.full(conversation, acting_user: @human).fetch(:memory_context))
  end

  # THE ROW'S CLOCK (owner 2026-09-15, item 12): `deliver_at` by presence
  # — the time the kernel holds on a scheduled row, absent on an untimed one.
  test "deliver_at rides the input by presence" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    actor = Speakers::Resolve.member(account: conversation.account, user: @human)
    at = Time.utc(2026, 9, 16, 9, 0, 0)
    scheduled = conversation.conversation_inputs.create!(
      account: conversation.account, queue_position: 0, kind: "direct_reply", role: "user",
      state: "pending", delivery_mode: "queue", speaker: actor, authoring_user: @human,
      answering_user: @human, deliver_at: at
    )
    plain = conversation.conversation_inputs.create!(
      account: conversation.account, queue_position: 1, kind: "message", role: "user",
      state: "pending", delivery_mode: "queue", speaker: actor, authoring_user: @human,
      answering_user: @human
    )

    assert_equal at, AgentAPI::ConversationPresenter.input(scheduled).fetch(:deliver_at)
    assert_not AgentAPI::ConversationPresenter.input(plain).key?(:deliver_at), "absent when the row carries none"
  end

  private

    # A settled turn with one candidate: its `content` body, and for a reply the seed under `prompt`
    # as `keep_prompt` clones it — `readable_text` given as the door gives it for a person's
    # message.
    def settled_turn!(conversation, actor, position:, kind:, role:, content:, prompt: nil, memory_context: nil)
      turn = ConversationTurn.create!(
        account: conversation.account, conversation: conversation, position: position,
        kind: kind, role: role, status: "completed", speaker: actor, control_owner_user: @human,
        answering_user: (users(:agent) if role == "assistant")
      )
      variant = ConversationTurnVariant.create!(
        account: conversation.account, conversation_turn: turn, position: 0, status: "completed", source: "inference",
        memory_context: memory_context
      )
      ContentBodies::Replace.call(owner: variant, role: "content", entries: [{ "text" => content }],
        readable_text: content, seal: true)
      ContentBodies::Replace.call(owner: variant, role: "prompt", **prompt, seal: true) if prompt
      turn.update!(active_variant: variant)
      turn
    end
end
