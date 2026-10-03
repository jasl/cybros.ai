module AgentLoops
  # Generation ownership survives joins and references. It supplies cancellation
  # targets and preserves a script's result boundary across later appends.
  module ExpansionOwnership
    module_function

    def descendants(node)
      AgentLoopNode.find_by_sql([<<~SQL, { root: node.id, loop: node.agent_loop_id }])
        WITH RECURSIVE generated(id) AS (
          SELECT id FROM agent_loop_nodes WHERE expansion_parent_id = :root
            AND agent_loop_id = :loop
          UNION ALL
          SELECT child.id FROM agent_loop_nodes child
            JOIN generated ON child.expansion_parent_id = generated.id
            WHERE child.agent_loop_id = :loop
        )
        SELECT agent_loop_nodes.* FROM agent_loop_nodes
          JOIN generated ON generated.id = agent_loop_nodes.id
        ORDER BY agent_loop_nodes.id
      SQL
    end

    # How deep a stage is nested, itself counted: its own script, the script
    # whose expansion placed it, and on up the unbroken run of script parents
    # (a compose call or an authored root ends it). Counted no further than
    # `limit`, so asking whether a stage is past a cap reads cap + 1 rows.
    def stage_depth(node, limit:)
      binds = { node: node.id, loop: node.agent_loop_id, script: AgentLoopNodes::ScriptTask.sti_name, limit: limit }
      sql = AgentLoopNode.sanitize_sql_array([<<~SQL, binds])
        WITH RECURSIVE stages(id, expansion_parent_id, depth) AS (
          SELECT id, expansion_parent_id, 1 FROM agent_loop_nodes
            WHERE id = :node AND type = :script
          UNION ALL
          SELECT parent.id, parent.expansion_parent_id, stages.depth + 1
            FROM stages JOIN agent_loop_nodes parent ON parent.id = stages.expansion_parent_id
            WHERE stages.depth < :limit AND parent.agent_loop_id = :loop AND parent.type = :script
        )
        SELECT COALESCE(MAX(depth), 0) FROM stages
      SQL
      AgentLoopNode.with_connection { |connection| connection.select_value(sql) }
    end

    # WHAT STANDS FOR A ROW NOW, for each key this loop holds: the row
    # itself, or — once an expansion replaced it (a child placed from the
    # row's own tip waits on it, the wake's retired fact) — that
    # expansion's final waits, followed down every later replacement: a
    # round's last continuation, a stage's final leaf, a composed call's
    # await. A final wait is a child no sibling waits on through written
    # order, reached from the row through its siblings, and on the
    # expansion's own path: not a step its author detached, and not a
    # spawn's delegation, which the delegation's settlement hands its
    # readers itself. One recursive query; a key the loop lacks is absent.
    def standing(agent_loop, keys)
      return {} if keys.empty?

      binds = { loop: agent_loop.id, keys: keys.uniq, delegation: AgentLoopNodes::DelegationTask.sti_name }
      sql = AgentLoopNode.sanitize_sql_array([<<~SQL, binds])
        WITH RECURSIVE standing(name, node_id, detached) AS (
          SELECT node_key, id, detached FROM agent_loop_nodes
            WHERE agent_loop_id = :loop AND node_key IN (:keys)
          UNION
          SELECT standing.name, child.id, standing.detached FROM standing
            JOIN agent_loop_nodes child ON child.expansion_parent_id = standing.node_id
            WHERE child.agent_loop_id = :loop AND child.detached = standing.detached
              AND child.type <> :delegation
              AND EXISTS (
                SELECT 1 FROM agent_loop_edges edges JOIN agent_loop_nodes sources ON sources.id = edges.from_node_id
                WHERE edges.to_node_id = child.id AND edges.structural
                  AND (sources.id = standing.node_id OR sources.expansion_parent_id = standing.node_id)
              )
              AND NOT EXISTS (
                SELECT 1 FROM agent_loop_edges edges JOIN agent_loop_nodes targets ON targets.id = edges.to_node_id
                WHERE edges.from_node_id = child.id AND edges.structural
                  AND targets.expansion_parent_id = standing.node_id
              )
        )
        SELECT standing.name, nodes.node_key FROM standing
          JOIN agent_loop_nodes nodes ON nodes.id = standing.node_id
          WHERE NOT EXISTS (
            SELECT 1 FROM agent_loop_edges expansions
            JOIN agent_loop_nodes children ON children.id = expansions.to_node_id
            WHERE expansions.from_node_id = nodes.id AND expansions.structural
              AND children.expansion_parent_id = nodes.id
          )
          ORDER BY standing.name, nodes.id
      SQL
      AgentLoopNode.with_connection { |connection| connection.select_rows(sql) }
        .group_by(&:first).transform_values { |rows| rows.map(&:last) }
    end

    # THE STAGES A ROW SITS BEHIND, nearest first: for each key with a
    # script at or above it on its expansion ancestry, that chain of script
    # keys — a stage's own value is behind its result boundary too, so a
    # script is its own nearest owner. One batched query; the walk stops at
    # a round on the loop's own path, which no stage ever expands into, so it
    # never climbs the spine's history.
    def owners(agent_loop, keys)
      return {} if keys.empty?

      binds = { loop: agent_loop.id, keys: keys.uniq, round: Tasks::Compile::ROUND,
                script: AgentLoopNodes::ScriptTask.sti_name }
      sql = AgentLoopNode.sanitize_sql_array([<<~SQL, binds])
        WITH RECURSIVE ancestry(subject, row_key, parent_id, type, mark, depth) AS (
          SELECT node_key, node_key, expansion_parent_id, type, continuation_source, 0 FROM agent_loop_nodes
            WHERE agent_loop_id = :loop AND node_key IN (:keys)
          UNION ALL
          SELECT ancestry.subject, parent.node_key, parent.expansion_parent_id, parent.type,
                 parent.continuation_source, ancestry.depth + 1
            FROM ancestry JOIN agent_loop_nodes parent ON parent.id = ancestry.parent_id
            WHERE ancestry.mark IS DISTINCT FROM :round AND parent.agent_loop_id = :loop
        )
        SELECT subject, row_key FROM ancestry WHERE type = :script ORDER BY subject, depth
      SQL
      AgentLoopNode.with_connection { |connection| connection.select_rows(sql) }
        .group_by(&:first).transform_values { |rows| rows.map(&:last) }
    end
  end
end
