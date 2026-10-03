require "test_helper"

class Executors::AttachmentsTest < ActiveSupport::TestCase
  Loop = Data.define(:account, :conversation_turn_variant, :agent_loop_nodes)

  setup do
    @account = accounts(:cybros)
    @user = users(:member)
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @user)
    @actor = Actor.create!(account: @account, kind: "member", user: @user,
      channel_key: "attachments", external_id: @user.public_id, display_name: "Member")
  end

  test "prior visible active variants and this exact prompt are available but other variants and later turns are not" do
    previous, prior = attached_turn(@conversation, 0)
    alternative = attached_variant(previous, role: "content", activate: false)
    current, own = attached_turn(@conversation, 1, role: "prompt")
    _future, later = attached_turn(@conversation, 2)
    loop = loop_for(current.active_variant)

    assert_equal prior, find(loop, prior)
    assert_equal own, find(loop, own)
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, alternative) }
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, later) }
    previous.update!(visibility: "excluded_from_context")
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, prior) }
    previous.update!(visibility: "hidden")
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, prior) }
    previous.update!(deleted_at: Time.current)
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, prior) }
  end

  test "a fork reads only its reachable prefix and honors its own concealment overrides" do
    inherited, allowed = attached_turn(@conversation, 0)
    _beyond, excluded = attached_turn(@conversation, 1)
    child = Conversation.create!(workspace: @conversation.workspace, creating_user: @user)
    ConversationAncestry.create!(account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: 0)
    current, _own = attached_turn(child, 1, role: "prompt")
    loop = loop_for(current.active_variant)
    assert_equal allowed, find(loop, allowed)
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, excluded) }
    ConversationTurnOverride.create!(account: @account, conversation: child,
      conversation_turn: inherited, visibility: "excluded_from_context")
    assert_raises(ActiveRecord::RecordNotFound) { find(loop, allowed) }
  end

  test "compaction does not revoke an existing reference to an earlier bound input" do
    _previous, file = attached_turn(@conversation, 0)
    summary = turn(@conversation, 1, kind: "compaction_summary")
    attached_variant(summary, role: "content")
    current, _own = attached_turn(@conversation, 2, role: "prompt")
    assert_equal file, find(loop_for(current.active_variant), file)
  end

  private

    def loop_for(variant)
      Loop.new(account: @account, conversation_turn_variant: variant, agent_loop_nodes: AgentLoopNode.none)
    end

    def find(loop, file) = Executors::Attachments.fetch(agent_loop: loop, public_id: file.public_id)

    def turn(conversation, position, kind: "message")
      ConversationTurn.create!(account: @account, conversation: conversation, position: position,
        kind: kind, role: "user", status: "completed", speaker_actor: @actor, control_owner_user: @user)
    end

    def attached_turn(conversation, position, role: "content")
      row = turn(conversation, position)
      [row, attached_variant(row, role: role)]
    end

    def attached_variant(turn, role:, activate: true)
      variant = ConversationTurnVariant.create!(account: @account, conversation_turn: turn,
        position: turn.conversation_turn_variants.count, status: "completed", source: "manual")
      upload = @account.content_uploads.create!(creating_user: @user,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new("document"), filename: "notes.txt",
          content_type: "text/plain", identify: false))
      ContentBodies::Replace.call(owner: variant, role: role, seal: true, uploads: [upload],
        entries: [{ "role" => "user", "parts" => [{ "type" => "upload", "upload_public_id" => upload.public_id }] }])
      turn.update!(active_variant: variant) if activate
      upload
    end
end
