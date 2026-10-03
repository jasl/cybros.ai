module AgentLoops
  # THE BRANCH-TIP FINDER: ONE descendant-closure walk along outgoing edges
  # from the call key the model saw (`r3t1`, whose branch hangs off it) or
  # any branch node, never crossing a round-marked node or a barrier — a
  # blocking task's spine consumer, the wake and a barrier's follower are
  # the spine's. The person-side cancel takes the members; a later reader
  # of history takes the TIP, the branch's last word, to pair a `task` call
  # with.
  module BranchClosure
    # A member with the branch consumers the walk found beyond it.
    Member = Data.define(:row, :consumers)

    module_function

    # The target itself when it is branch work, else — for a `task`/`ask`
    # call — the branch it started; then every descendant that is branch
    # work, never crossing a round-marked node or a barrier.
    def members(node)
      return [node, *ExpansionOwnership.descendants(node)] if node.script?

      # A directly named spawn wait is only the finite pause, even when its
      # consumer is itself a detached branch. Its caller must resume and its
      # separate completion obligation must survive.
      if node.await? && node.incoming_edges.includes(:from_node).any? { |edge| spawn_call?(edge.from_node) }
        [node]
      else
        rows = closure(node).values.map(&:row)
        rows.flat_map { |row| row.script? ? [row, *ExpansionOwnership.descendants(row)] : [row] }.uniq(&:id)
      end
    end

    # The branch's last round: the round-marked member with no round
    # downstream of it inside the branch — where the chain ends today,
    # settled or not. A continuation is consumed through its fan (the
    # round it reads rides `input_from`), so "no round consumer" would
    # name the root. Nil off a branch.
    def tip_of(call)
      # A waited spawn's tip is its await: the child runs elsewhere; the
      # await is the branch's whole word here.
      if spawn_call?(call)
        completion = call.spawn_delegation
        # Only a consumer of this original fan can have substituted completion
        # for its paired wait. A later wake carries its own message and must
        # not retroactively replace the launch acknowledgement in history.
        paired = completion && call.agent_loop.agent_loop_nodes
          .where("? = ANY(input_from_node_keys) AND ? = ANY(input_from_node_keys)",
            call.node_key, completion.node_key).exists?
        return paired ? completion : call.spawn_await
      end

      closed = closure(call)
      closed.values.map(&:row).select(&:round?).find { |round| !round_below?(closed, round) }
    end

    # The `task`/`spawn` calls whose tip a reader renders as the call's paired
    # result, by the loop and call's key: the tip is settled and NOT mailed — a
    # mailed tip's delivery is the mail, and rendering it at the call too would
    # put one result in history twice. An ask's answer is read material the await
    # delivers, never a paired result.
    def tips_by_call_key(calls)
      calls.select { |call| BranchTools::PAIRED_VERBS.include?(call.tool_name) }
        .to_h { |call| [[call.agent_loop_id, call.node_key], tip_of(call)] }
        .compact
        .select do |(loop_id, call_key), tip|
          # A later wake delivers its own material. Only the original fan's
          # consumer can replace this call's launch acknowledgement.
          tip.terminal? && tip.mailed_at.nil? && AgentLoopNode.where(agent_loop_id: loop_id)
            .where("? = ANY(input_from_node_keys) AND ? = ANY(input_from_node_keys)", call_key, tip.node_key).exists?
        end
    end

    # Discovery order from the roots, keyed by row id; every consumer a
    # member names is itself a member, so the closure is walkable offline.
    def closure(node)
      roots = branch?(node) ? [node] : (flat_call?(node) ? branch_consumers(node) : [])
      closed = {}
      frontier = roots.dup
      until frontier.empty?
        row = frontier.shift
        next if closed.key?(row.id)

        consumers = branch_consumers(row)
        closed[row.id] = Member.new(row: row, consumers: consumers)
        frontier.concat(consumers)
      end
      closed
    end

    def round_below?(closed, row)
      seen = Set.new
      frontier = closed.fetch(row.id).consumers.dup
      until frontier.empty?
        below = frontier.shift
        next unless seen.add?(below.id)
        return true if below.round?

        frontier.concat(closed.fetch(below.id).consumers)
      end
      false
    end

    # A spawn call owns its finite await and, for turn lifetime, completion.
    # Naming the await itself cancels only the short wait; naming the call
    # includes its completion obligation and therefore the original child work.
    def branch_consumers(node)
      node.outgoing_edges.where(structural: true).includes(:to_node).order(:id).map(&:to_node)
        .select { |row| branch?(row) || (row.await? && spawn_call?(node)) }
    end

    # Branch work: a detached row, a branch-marked round, or a call or
    # await a branch-marked round emitted. A barrier is the spine's.
    def branch?(row)
      return false if row.join_mode.present?
      return true if row.detached?
      return row.continuation_source == Tasks::Compile::BRANCH if row.round? || row.script?

      if row.expansion_parent_id
        parent = row.expansion_parent
        return parent.script? || branch?(parent)
      end

      KernelTool.round_of(row)&.continuation_source == Tasks::Compile::BRANCH
    end

    def flat_call?(row) = row.tool_call? && BranchTools::FLAT_VERBS.include?(row.tool_name)
    def spawn_call?(row) = row.tool_call? && row.tool_name == "spawn"
  end
end
