module Conversations
  # A lifecycle verb on a root stamps the whole subagent tree at command
  # time, so lifecycle state lands on each child's own column and no read
  # path walks a parent chain.
  module SubagentTree
    module_function

    # The root plus every transitive subagent child, one recursive CTE.
    # Caller holds the root's row lock, which serializes competing lifecycle
    # commands on the same tree.
    def member_ids(root)
      members(root).pluck(:id)
    end

    def members(root)
      first = Conversation.where(id: root.id).select(:id)
      descendants = Conversation.joins("JOIN subagent_tree ON conversations.parent_conversation_id = subagent_tree.id")
        .where(taken_over_at: nil).select(:id)
      ids = Conversation.with_recursive(subagent_tree: [first, descendants])
        .from("subagent_tree").select("subagent_tree.id")
      Conversation.where(id: ids)
    end

    def root(conversation)
      return conversation unless conversation.parent_conversation_id && !conversation.taken_over_at

      first = Conversation.where(id: conversation.id).select(:id, :parent_conversation_id, :taken_over_at)
      parents = Conversation.joins("JOIN subagent_ancestors ON conversations.id = subagent_ancestors.parent_conversation_id")
        .where("subagent_ancestors.taken_over_at IS NULL")
        .select(:id, :parent_conversation_id, :taken_over_at)
      roots = Conversation.with_recursive(subagent_ancestors: [first, parents])
        .from("subagent_ancestors")
        .where("subagent_ancestors.parent_conversation_id IS NULL OR subagent_ancestors.taken_over_at IS NOT NULL")
        .select("subagent_ancestors.id")
      Conversation.find_by!(id: roots)
    end

    # A takeover can move the lifecycle root while a caller waits for its old
    # root. Release that obsolete lock before looking again. Every retry crosses
    # a permanently detached ancestor; the original ancestor chain only shrinks.
    def with_root(conversation, requires_new: false)
      loop do
        current = root(conversation.reload)
        changed = false
        result = current.with_lock(requires_new: requires_new) do
          if root(conversation.reload).id != current.id
            changed = true
          else
            yield current
          end
        end
        return result unless changed
      end
    end

    # Whether `candidate` is strictly ABOVE `conversation` in the tree —
    # the door's refusal predicate: a subagent's `cancel` or `send`
    # addressed at one of its own ancestors would stop or steer the turn
    # it runs under. Lock-free: a request observes current membership;
    # takeover removes an edge without altering birth provenance.
    def ancestor?(candidate, conversation)
      candidate.id != conversation.id && member_ids(candidate).include?(conversation.id)
    end
  end
end
