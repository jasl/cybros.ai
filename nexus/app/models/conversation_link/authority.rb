module ConversationLink::Authority
  extend ActiveSupport::Concern

  class_methods do
    # Authority commands hold their actual owner. These indexed set writes cut
    # grants in that transaction; the existing Input recovery frontier removes
    # queued messages. Bulk cuts use the authority owner's existing notification,
    # without synchronous per-link events, Run cancellation or queue traversal.
    def close_scope(scope, reason:)
      now = Time.current
      scope.active.update_all(closed_at: now, close_reason: reason, updated_at: now)
    end

    def close_for_principal(user, reason: "principal_unavailable")
      agents = user.human? ? User.where(steward_id: user.id).select(:id) : [user.id]
      close_scope(where(first_agent_id: agents).or(where(second_agent_id: agents)), reason: reason)
    end

    def close_for_endpoint(conversation)
      entries = ConversationAccessEntry.where(conversation_id: conversation.id)
      derived = [conversation.creating_user_id, conversation.answering_user_id]
      first = where(first_conversation_id: conversation.id)
      second = where(second_conversation_id: conversation.id)
      if conversation.access_full?
        denied = entries.where.not(level: "full").where.not(user_id: derived).select(:user_id)
        affected = first.where(first_agent_id: denied).or(second.where(second_agent_id: denied))
      else
        allowed = entries.where(level: "full").select(:user_id)
        affected = first.where.not(first_agent_id: derived).where.not(first_agent_id: allowed)
          .or(second.where.not(second_agent_id: derived).where.not(second_agent_id: allowed))
      end
      close_scope(affected, reason: "endpoint_access_lost")
    end

    def close_for_workspace_access(workspace)
      return 0 if workspace.account_wide?

      agents = User.where(steward_id: workspace.owner_id).select(:id)
      scope = where(workspace_id: workspace.id)
      close_scope(scope.where.not(first_agent_id: agents).or(scope.where.not(second_agent_id: agents)),
        reason: "workspace_access_lost")
    end
  end
end
