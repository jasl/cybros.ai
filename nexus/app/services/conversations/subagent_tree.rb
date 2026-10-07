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
      sql = ApplicationRecord.sanitize_sql_array([<<~SQL, root.id])
        WITH RECURSIVE subagent_tree AS (
          SELECT id FROM conversations WHERE id = ?
          UNION ALL
          SELECT c.id
          FROM conversations c
          JOIN subagent_tree t ON c.parent_conversation_id = t.id
        )
        SELECT id FROM subagent_tree
      SQL
      ApplicationRecord.lease_connection.select_values(sql)
    end

    # Whether `candidate` is strictly ABOVE `conversation` in the tree —
    # the door's refusal predicate: a subagent's `cancel` or `send`
    # addressed at one of its own ancestors would stop or steer the turn
    # it runs under. Lock-free: a tree grows only by spawn, and a stale
    # read refuses nothing it should admit.
    def ancestor?(candidate, conversation)
      candidate.id != conversation.id && member_ids(candidate).include?(conversation.id)
    end
  end
end
