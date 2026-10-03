module AgentLoops
  # WHAT COMES BACK TO THE CALLER, and WHEN — one set for a waited head and
  # for the wake. The set: every result no step reads
  # (`Nexus::Compose::Reads.unread`), where a race's barrier stands for every
  # row placed in its arms, an expansion for the row it replaced, a stage's
  # insides stay behind its boundary, and a turn-owned spawn's delegation
  # owns the child's one report, so the short await beside it never comes
  # back — a consumer only rows hold, decided by the rows' loader. The
  # moment: once nothing that waits on a result is still live, so a
  # structural wait defers delivery and never consumes it, and a chain comes
  # back whole when its last step settles.
  module Delivery
    module_function

    def unread(keys, named:, members:, internal:, retired:) =
      Nexus::Compose::Reads.unread(keys, named: named, members: members, internal: internal, retired: retired)

    # THE ENVELOPE'S LOADER, the waited head's: the compiled payloads before
    # anything has expanded, so nothing is retired and no stage has insides
    # yet. `keys` are the rows the head waits for, in placement order.
    def compiled(payloads, keys)
      named = payloads.flat_map do |payload|
        Array(payload["input_from_node_keys"]) + Array(payload["result_from_node_keys"])
      end
      members = payloads.select { |payload| payload["barrier_key"] }.map { |payload| payload["node_key"] }
      unread(keys, named: named, members: members, internal: [], retired: [])
    end

    # THE ROWS' LOADER, the wake's and the mail's, over the settled rows the
    # sink query left (`WakeContinuation.undelivered`). Named, arm and
    # replaced rows are that query's anti-joins, since those sets grow with
    # the loop's whole history; a stage's insides are decided here, over the
    # few rows left. Then the timing rule.
    def settled(agent_loop, rows, standalone:)
      keys = unread(rows.map(&:node_key), named: [], members: [], internal: internal(agent_loop, rows), retired: [])
      ready(agent_loop, rows.select { |row| keys.include?(row.node_key) }, standalone: standalone)
    end

    # A STAGE'S INSIDES: a row behind a stage's boundary that is not what
    # crosses it — it has a structural successor inside the same outermost
    # stage, where a stage's final leaf waits on nothing inside (its
    # consumers are outside, or a nested stage's are the outer stage's own
    # steps). One owners query, and two more only when a row has an owner.
    def internal(agent_loop, rows)
      owned = ExpansionOwnership.owners(agent_loop, rows.map(&:node_key))
      return [] if owned.empty?

      inside = rows.select { |row| owned.key?(row.node_key) }
      successors = agent_loop.agent_loop_nodes
        .joins("JOIN agent_loop_edges edges ON edges.to_node_id = agent_loop_nodes.id")
        .where(edges: { from_node_id: inside.map(&:id), structural: true })
        .pluck("edges.from_node_id", :node_key)
      outer = ExpansionOwnership.owners(agent_loop, successors.map(&:last))
      keys = inside.index_by(&:id)
      successors.filter_map do |from_id, to_key|
        key = keys.fetch(from_id).node_key
        key if owned.fetch(key).last == outer[to_key]&.last
      end.uniq
    end

    # THE TIMING RULE: a row is ready once no row that waits on it through
    # written order, transitively, is live — among the ones its caller waits
    # for: a turn-owned result is never held behind cross-turn background
    # work, which may outlive the turn that owes it (a standalone loop awaits
    # everything) — and none of a settled race's arms, whose selection
    # already stands for them: a loser running out holds nothing back. One
    # recursive query forward over structural edges; a reference edge never
    # holds a result back.
    def ready(agent_loop, rows, standalone:)
      return rows if rows.empty?

      binds = { loop: agent_loop.id, ids: rows.map(&:id), live: AgentLoopNode::LIVE_STATUSES, standalone: standalone,
                terminal: AgentLoopNode::TERMINAL_STATUSES }
      sql = AgentLoopNode.sanitize_sql_array([<<~SQL, binds])
        WITH RECURSIVE descendants(root_id, node_id) AS (
          SELECT from_node_id, to_node_id FROM agent_loop_edges
            WHERE agent_loop_id = :loop AND structural AND from_node_id IN (:ids)
          UNION
          SELECT descendants.root_id, edges.to_node_id FROM agent_loop_edges edges
            JOIN descendants ON edges.from_node_id = descendants.node_id
            WHERE edges.agent_loop_id = :loop AND edges.structural
        )
        SELECT DISTINCT descendants.root_id FROM descendants
          JOIN agent_loop_nodes roots ON roots.id = descendants.root_id
          JOIN agent_loop_nodes nodes ON nodes.id = descendants.node_id
          LEFT JOIN agent_loop_nodes barriers ON barriers.id = nodes.barrier_node_id
          WHERE nodes.status IN (:live)
            AND (barriers.id IS NULL OR barriers.status NOT IN (:terminal))
            AND (:standalone OR roots.lifetime = 'conversation' OR NOT nodes.detached OR nodes.lifetime = 'turn')
      SQL
      blocked = AgentLoopNode.with_connection { |connection| connection.select_values(sql) }.to_set
      rows.reject { |row| blocked.include?(row.id) }
    end
  end
end
