module MemoryCollectionsHelper
  def memory_collection_name(collection)
    collection.name.presence || t(collection.is_default ? "memory_collections.default_name" : "memory_collections.unnamed")
  end

  def memory_collection_owner(collection)
    memory_owner_name(collection.owner, scope: collection.natural_scope)
  end

  def memory_owner_name(owner, scope:)
    case scope
    when :conversation then conversation_title(owner)
    when :workspace then owner.name
    when :user, :agent, :speaker then owner.display_name
    else raise ArgumentError, "unknown memory owner"
    end
  end

  def memory_owner_path(owner, scope:)
    case scope
    when :conversation then conversation_path(owner)
    when :workspace then workspace_path(owner)
    when :user then memory_collections_path
    else raise ArgumentError, "unknown console memory owner"
    end
  end
end
