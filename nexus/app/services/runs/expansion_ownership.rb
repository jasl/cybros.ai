module Runs
  # Generation ownership survives joins and references. It supplies cancellation
  # targets and preserves a task's result boundary across later appends.
  module ExpansionOwnership
    module_function

    def descendants(node)
      Task.find_by_sql([<<~SQL, { root: node.id, loop: node.run_id }])
        WITH RECURSIVE generated(id) AS (
          SELECT id FROM tasks WHERE expansion_parent_id = :root
            AND run_id = :loop
          UNION ALL
          SELECT child.id FROM tasks child
            JOIN generated ON child.expansion_parent_id = generated.id
            WHERE child.run_id = :loop
        )
        SELECT tasks.* FROM tasks
          JOIN generated ON generated.id = tasks.id
        ORDER BY tasks.id
      SQL
    end

    # A tool with accepted operations returns its own final value. Its children stay behind
    # that boundary until an accepted background operation releases them.
    # Release is an operation fact, not inferred from the parent's detachment.
    def operation_owners(run, keys, include_self: false)
      return {} if keys.empty?

      binds = { loop: run.id, keys: keys.uniq, include_self: include_self, round: Tasks::Compile::ROUND }
      # Build release facts once, rather than recomputing them at recursive ancestry probes.
      sql = Task.sanitize_sql_array([<<~SQL, binds])
        WITH RECURSIVE released(parent_id, child_key) AS MATERIALIZED (
          SELECT operation.task_id,
                 jsonb_array_elements_text(operation.response->'receipt'->'task_keys')
            FROM task_operations operation
            JOIN tasks owner ON owner.id = operation.task_id
            WHERE owner.run_id = :loop AND (
              operation.response->'receipt'->'background' = 'true'::jsonb OR EXISTS (
                SELECT 1 FROM task_operations release
                  WHERE release.task_id = owner.id
                    AND release.response->'receipt'->'released_operations' @> jsonb_build_array(operation.operation_key)
              )
            )
        ), ancestry(subject, row_key, parent_id, operation_owner, mark, depth) AS (
          SELECT node_key, node_key, expansion_parent_id,
                 EXISTS (SELECT 1 FROM task_operations WHERE task_id = tasks.id),
                 continuation_source, 0 FROM tasks
            WHERE run_id = :loop AND node_key IN (:keys)
          UNION ALL
          SELECT ancestry.subject, parent.node_key, parent.expansion_parent_id,
                 EXISTS (SELECT 1 FROM task_operations WHERE task_id = parent.id),
                 parent.continuation_source, ancestry.depth + 1
            FROM ancestry JOIN tasks parent ON parent.id = ancestry.parent_id
            WHERE ancestry.mark IS DISTINCT FROM :round AND parent.run_id = :loop AND NOT EXISTS (
              SELECT 1 FROM released WHERE released.parent_id = parent.id AND released.child_key = ancestry.row_key
            )
        )
        SELECT subject, row_key FROM ancestry WHERE operation_owner AND (depth > 0 OR :include_self) ORDER BY subject, depth
      SQL
      Task.with_connection { |connection| connection.select_rows(sql) }
        .group_by(&:first).transform_values { |rows| rows.map(&:last) }
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
    def standing(run, keys)
      return {} if keys.empty?

      binds = { loop: run.id, keys: keys.uniq, delegation: ::Tasks::DelegationTask.sti_name }
      sql = Task.sanitize_sql_array([<<~SQL, binds])
        WITH RECURSIVE standing(name, node_id, detached) AS (
          SELECT node_key, id, detached FROM tasks
            WHERE run_id = :loop AND node_key IN (:keys)
          UNION
          SELECT standing.name, child.id, standing.detached FROM standing
            JOIN tasks child ON child.expansion_parent_id = standing.node_id
            WHERE child.run_id = :loop AND child.detached = standing.detached
              AND child.type <> :delegation
              AND EXISTS (
                SELECT 1 FROM run_edges edges JOIN tasks sources ON sources.id = edges.from_node_id
                WHERE edges.to_node_id = child.id AND edges.structural
                  AND (sources.id = standing.node_id OR sources.expansion_parent_id = standing.node_id)
              )
              AND NOT EXISTS (
                SELECT 1 FROM run_edges edges JOIN tasks targets ON targets.id = edges.to_node_id
                WHERE edges.from_node_id = child.id AND edges.structural
                  AND targets.expansion_parent_id = standing.node_id
              )
        )
        SELECT standing.name, nodes.node_key FROM standing
          JOIN tasks nodes ON nodes.id = standing.node_id
          WHERE NOT EXISTS (
            #{replacement_query(node_alias: "nodes")}
          )
          ORDER BY standing.name, nodes.id
      SQL
      Task.with_connection { |connection| connection.select_rows(sql) }
        .group_by(&:first).transform_values { |rows| rows.map(&:last) }
    end

    # The exact relation that removes the original row from standing. Readiness
    # discovery also uses it: an unexpanded nonterminal root must still be waited
    # on, while an expanded root may already stand for a canceled replacement.
    def replacement_query(node_alias:)
      <<~SQL
        SELECT 1 FROM run_edges expansions
        JOIN tasks children ON children.id = expansions.to_node_id
        WHERE expansions.from_node_id = #{node_alias}.id AND expansions.structural
          AND children.expansion_parent_id = #{node_alias}.id
      SQL
    end

    # A result crosses its operation owner's boundary when read from outside it.
    # Include the owner's own final value for these material readers.
    def owners(run, keys) = operation_owners(run, keys, include_self: true)
  end
end
