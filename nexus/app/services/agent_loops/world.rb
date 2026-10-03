module AgentLoops
  # THE WORLD A LOOP TOUCHED, DERIVED: a fact read off rows the kernel
  # already keeps — `addressed_role`, the `effect_profile` frozen at
  # dispatch, the claim, the runner's own `result_metadata` — no column, no
  # migration, no prediction. "Touched" is a RUNNER-addressed write-kind call
  # a runner CLAIMED: the claim is the moment the effect may have happened; a
  # row nobody claimed touched nothing; a kernel tool (`memory_write`) is
  # never the world. The fact carries the runner's record under
  # `metadata.checkpoint` VERBATIM — any JSON the runner stored, a `{hash,
  # store}`, a `{skipped, …}`, a placeholder — and the claimant column as
  # `runner`. The kernel compares nothing and reads nothing inside the
  # record; whether THIS conversation's bound runner can restore it is the
  # reader's comparison (the SDK's), never a word here.
  module World
    module_function

    # The one predicate every reader shares: runner-addressed, write-kind
    # as frozen at dispatch, claimed. The jsonb read is unindexed, like
    # `type`; every caller bounds it by loop ids or by a timeline's reach.
    def writes(scope)
      scope
        .where(type: AgentLoopNodes::ToolTask.name, addressed_role: "runner")
        .where("agent_loop_nodes.effect_profile->>'kind' = 'write'")
        .where.not(claimed_at: nil)
    end

    # The rows a fact is built from, with the loop's public id selected
    # beside them so `fact` costs no second read.
    def rows(scope)
      writes(scope).joins(:agent_loop).select("agent_loop_nodes.*", "agent_loops.public_id AS loop_public_id")
    end

    # ONE windowed query, `Transcript.newest_rounds`'s form: the FIRST such
    # row of every loop named, keyed by loop id — position 1 of
    # `ROW_NUMBER() OVER (PARTITION BY agent_loop_id ORDER BY claimed_at, id)`. A loop
    # with no such row is absent, and `fact(nil)` says `untouched`.
    def first_writes(agent_loop_ids)
      return {} if agent_loop_ids.empty?

      windowed = rows(AgentLoopNode.where(agent_loop_id: agent_loop_ids)).select(
        "ROW_NUMBER() OVER (PARTITION BY agent_loop_nodes.agent_loop_id ORDER BY agent_loop_nodes.claimed_at, agent_loop_nodes.id) AS position"
      )
      AgentLoopNode.from(windowed, :ranked).select("ranked.*").where("ranked.position = 1").index_by(&:agent_loop_id)
    end

    # The wire object `world`. `checkpoint` rides only when the runner's
    # metadata carries the key — presence, never a reading of the value.
    def unavailable = { status: "unavailable", reason: "execution_details_pruned" }

    def fact(row, details_pruned_at: nil)
      return unavailable if details_pruned_at
      return { status: "untouched" } if row.nil?

      fact = { status: "touched", loop: row.loop_public_id, runner: row.claimed_by_executor_public_id }
      # `result_metadata` is a JSON object or null (the settle's bound).
      metadata = row.result_metadata.to_h
      fact[:checkpoint] = metadata["checkpoint"] if metadata.key?("checkpoint")
      fact
    end
  end
end
