module TurnConvergenceTestHelper
  private

    # Each healthy pair has its own busy conversation and needs no convergence.
    # Bulk setup keeps large source-plan fixtures outside the measured path.
    def seed_running_pairs(count)
      now = Time.current
      account = accounts(:cybros)
      human = users(:member)
      actor = Speakers::Resolve.member(account: account, user: human)
      conversation_ids = Conversation.insert_all!(Array.new(count) do
        { account_id: account.id, workspace_id: workspaces(:shared).id,
          creating_user_id: human.id, answering_user_id: human.id,
          timeline_position_head: 1, last_activity_at: now, created_at: now, updated_at: now }
      end, returning: %w[id]).rows.flatten
      turn_ids = Turn.insert_all!(conversation_ids.map do |conversation_id|
        { account_id: account.id, conversation_id: conversation_id, position: 0,
          kind: "direct_reply", role: "assistant", status: "running", speaker_id: actor.id,
          control_owner_user_id: human.id, answering_user_id: human.id, created_at: now, updated_at: now }
      end, returning: %w[id]).rows.flatten
      variant_ids = Variant.insert_all!(turn_ids.map do |turn_id|
        { account_id: account.id, turn_id: turn_id, position: 0,
          status: "running", source: "run", created_at: now, updated_at: now }
      end, returning: %w[id]).rows.flatten
      Run.insert_all!(variant_ids.map do |variant_id|
        { account_id: account.id, workspace_id: workspaces(:shared).id, creating_user_id: human.id,
          status: "running", variant_id: variant_id, approval_mode: "bypass",
          started_at: now, created_at: now, updated_at: now }
      end)
      Turn.where(id: turn_ids).update_all(<<~SQL.squish)
        active_variant_id = (SELECT id FROM variants
          WHERE turn_id = turns.id AND status = 'running' AND deleted_at IS NULL)
      SQL
      Conversation.where(id: conversation_ids).update_all(<<~SQL.squish)
        active_turn_id = (SELECT id FROM turns
          WHERE conversation_id = conversations.id AND status = 'running')
      SQL
    end
end
