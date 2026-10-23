module MemoryCollections
  # Resource doors use owner authority. A conversation binding is a separate,
  # narrower access path and never grants global Agent or Speaker management.
  class Access
    def initialize(by:)
      @by = by
    end

    def scope
      base = MemoryCollection.live.where(account_id: @by.account_id)
      base.where(user_id: users.select(:id))
        .or(base.where(workspace_id: Workspace.data_accessible_to(@by).browsable.select(:id)))
        .or(base.where(conversation_id: Conversation.visible_to(@by).select(:id)))
    end

    def users
      own = User.where(id: @by.id, status: :active)
      return own unless @by.agent_member?

      own.or(User.where(derived_from_id: @by.id, steward_id: @by.steward_id, status: :active)
        .where.not(named_agent_scope: nil))
    end

    def preload(collections)
      @levels = ConversationAccessEntry.where(conversation_id: collections.filter_map(&:conversation_id), user_id: @by.id)
        .pluck(:conversation_id, :level).to_h
      self
    end

    def manageable?(collection)
      owner_manageable?(collection.owner, scope: collection.natural_scope)
    end

    def with_management(collection)
      collection.with_mutation do
        next MemoryCollection::Result.refused(:not_authorized) unless manageable?(collection)

        yield
      end
    end

    def owner_manageable?(owner, scope:)
      case scope.to_sym
      when :workspace then owner.live? && owner.manageable_by?(@by)
      when :conversation then conversation_writable?(owner)
      when :user, :agent, :speaker then owner.active? && (owner == @by ||
        (@by.agent_member? && owner.derived_from_id == @by.id && owner.application_owner == @by))
      else raise ArgumentError, "unknown memory scope"
      end
    end

    def writable?(collection)
      return false if collection.deleted? || collection.archived?

      if collection.workspace_id
        collection.workspace.writable_by?(@by)
      else
        manageable?(collection)
      end
    end

    private

      def conversation_writable?(conversation)
        !conversation.tombstoned? && conversation.workspace.writable_by?(@by) &&
          conversation.access_level_for(@by, access_levels: @levels) == "full"
      end
  end
end
