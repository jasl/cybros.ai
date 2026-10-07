module Executors
  # A tools-provider pool: every active `tool_provider` announcing a name and
  # eligible for the loop's frozen principal — two providers announcing one
  # name are a pool of two, not a collision; a `user_private` provider under
  # another Human is no member. Non-kernel names only: a kernel name never
  # reaches here — addressing reads `kernel?` first, and the workspace's
  # override names ONE provider, never a pool. ONE reader, so addressing (who
  # the row is for) and the nudge (whose streams hear it) cannot disagree: the
  # design's lock-free containment query over the announcement, then the
  # eligibility predicate in Ruby — it reads credential readiness and the
  # shutdown fence, which are not SQL.
  module Pool
    ROLE = "tool_provider".freeze

    module_function

    def members(tool_name, principal)
      providers = TaskExecutor
        .where(executor_kind: ROLE, status: :active)
        .where("served_tools @> ?", [{ name: tool_name.to_s }].to_json)
        .order(:id)
        .preload(:manager)
        .to_a
      readiness = TaskExecutor.credential_readiness_for(providers)
      providers.select { |provider| provider.eligible_for?(principal, readiness:) }
    end

    # The ONE document a pool row freezes (reads one profile per row, and
    # the sweep's SQL twin one `timeout_ms`): the strictest announced.
    # Replayable only if EVERY member's entry is — a non-replayable member's
    # five keys are the row's, since any member may win the claim and the
    # sweep must not blind-replay what one of them may have effected; the
    # park is the SHORTEST announced timeout. Members announcing one entry
    # collapse to it. Members are id-ordered, so the pick is deterministic.
    def effect_profile(members, tool_name)
      entries = members.map { |provider| provider.serving(tool_name) }
      strictest = entries.find { |entry| !Nexus::ToolRegistry.replayable?(entry["effect_profile"]) } ||
        entries.first
      profile = strictest.fetch("effect_profile")
      timeout = entries.filter_map { |entry| entry["timeout_ms"] }.min
      timeout.nil? ? profile : profile.merge("timeout_ms" => timeout)
    end

    # A row addressed to the role alone, no executor.
    def row?(node)
      node.addressed_executor_id.nil? && node.addressed_role == ROLE
    end

    # Membership of THIS executor for THIS row, the claim's read: the kind,
    # the announcement; eligibility is the claim's own next fence.
    def member?(node, executor)
      row?(node) && executor.tool_provider? && executor.served?(node.tool_name)
    end
  end
end
