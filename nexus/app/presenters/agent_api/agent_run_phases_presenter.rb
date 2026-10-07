module AgentAPI
  # The phases projection: a phase is one top-level step of an authored
  # envelope, read from the receipts' step mirrors in write order; every
  # kernel round counts inside the phase it extends; nothing is stored to
  # answer it. `phases` on the wire, never `progress`: that word is the
  # executor plane's ephemeral feed, and one word carries one meaning.
  module AgentRunPhasesPresenter
    Phase = Data.define(:label, :keys, :done, :total, :status) do
      def to_h = super
    end

    Phases = Data.define(:phases, :current, :background, :spend) do
      def to_h = { phases: phases.map(&:to_h), current: current, background: background, spend: spend }
    end

    # The order a phase's word is chosen in: one live step names the
    # phase's state before any settled one does.
    PHASE_STATUSES = {
      "running" => %w[running dispatched],
      "awaiting_human" => %w[awaiting_input],
      "needs_approval" => %w[needs_approval],
    }.freeze

    class << self
      def call(agent_run)
        nodes = agent_run.agent_run_tasks.includes(:sources).order(:created_at, :id).to_a
        plans = agent_run.agent_run_append_receipts.order(:id)
          .pluck(:response_body).map { |body| Array(body["steps"]) }
        build(nodes: nodes, plans: plans, spend: spend_for(agent_run))
      end

      # Pure over loaded rows (or doubles shaped like them), so the contract
      # generator renders the same projection the route serves.
      def build(nodes:, plans:, spend:)
        by_key = nodes.index_by(&:node_key)
        phases = plans.flatten(1).map { |entry| [label_for(entry), keys_of(entry)] }
        members = phases.map { |_label, keys| keys.filter_map { |key| by_key[key] } }
        attach_kernel_rounds(nodes, phases, members, by_key)
        rows = phases.each_with_index.map do |(label, keys), index|
          Phase.new(
            label: label, keys: keys,
            done: keys.count { |key| terminal?(by_key[key]) }, total: keys.length,
            status: phase_status(members[index])
          )
        end
        Phases.new(
          phases: rows,
          current: rows.index { |phase| phase.status != "completed" },
          background: background(nodes),
          spend: spend
        )
      end

      private

        # A mirror entry is a key, or a group `{parallel: [...], key?}` whose
        # members are keys, groups, or nested sequences of either.
        def keys_of(entry)
          case entry
          when String then [entry]
          when Array then entry.flat_map { |member| keys_of(member) }
          else Array(entry["parallel"]).flat_map { |member| keys_of(member) } + [entry["key"]].compact
          end
        end

        # The one label word that exists is the key; a group is its members'.
        def label_for(entry)
          case entry
          when String then entry
          else Array(entry["parallel"]).flat_map { |member| keys_of(member) }.join(" · ")
          end
        end

        # A row no plan names — a tool fan, a continuation, a wake, composed
        # work — belongs to the phase of the round it extends, found by
        # walking its sources back to a named key. One walk over the loop:
        # every hop reads the one preloaded hop, resolved back to the loaded
        # rows, and an answer found is kept for every row on the path —
        # O(rows + edges), a constant number of queries.
        def attach_kernel_rounds(nodes, phases, members, by_key)
          phase_of = {}
          phases.each_with_index { |(_label, keys), index| keys.each { |key| phase_of[key] = index } }
          index_of = phase_of.dup
          sources_of = resolved_sources(nodes, by_key)
          nodes.each do |node|
            index = phase_index(node, index_of, sources_of)
            members[index] << node if index && !phase_of.key?(node.node_key)
          end
        end

        # The preloader hands each row its sources as fresh instances whose
        # own sources are unloaded; the loaded row of the same key is the
        # one whose hop is already in memory. A double resolves to itself.
        def resolved_sources(nodes, by_key)
          nodes.to_h do |node|
            [node.node_key, node.sources.map { |source| by_key.fetch(source.node_key, source) }]
          end
        end

        # Follow the model source first, else the first source, to a key
        # already answered; a row with no sources, or a path that closes on
        # itself, answers nil. `index_of` is the memo, never `phase_of`:
        # the plan's keys alone say which rows are authored.
        def phase_index(node, index_of, sources_of)
          path = []
          current = node
          until index_of.key?(current.node_key)
            sources = sources_of.fetch(current.node_key) { current.sources }
            break if sources.empty? || path.include?(current.node_key)

            path << current.node_key
            current = sources.find { |candidate| candidate.task_kind == "model_task" } || sources.first
          end
          index = index_of[current.node_key]
          path.each { |key| index_of[key] = index }
          index
        end

        def phase_status(rows)
          # A suspended program waits on its own children; only an ask's
          # awaiting_input state means a person must answer.
          statuses = rows.map do |row|
            row.status == "awaiting_input" && row.task_kind == "tool_task" ? "running" : row.status
          end
          live = PHASE_STATUSES.find { |_word, words| statuses.intersect?(words) }
          return live.first if live
          return "waiting" unless rows.all? { |row| terminal?(row) }

          rows.any? { |row| unresolved?(row) } ? "failed" : "completed"
        end

        def terminal?(row) = row && AgentRunTask::TERMINAL_STATUSES.include?(row.status)

        # The candidate rule over the row's own columns (the node's
        # `unresolved_failure?`, spelled over doubles): a failure nobody
        # adjudicated and no `absorb` policy resolves.
        def unresolved?(row)
          AgentRunTask::FAILURE_STATUSES.include?(row.status) && row.failure_resolution.nil? &&
            row.on_failure != "absorb"
        end

        # Detached work nothing waits on: the tips still to settle that a
        # later wake or mail will deliver, and the ones already mailed
        # after the reply was final, with their stamp.
        def background(nodes)
          waited = nodes.flat_map { |node| node.sources.map(&:node_key) }.to_set
          nodes.select do |node|
            node.detached && !waited.include?(node.node_key) && (!terminal?(node) || node.result_delivered_at)
          end.map do |node|
            { key: node.node_key, status: AgentRunPresenter.public_status(node.status),
              result_delivered_at: node.result_delivered_at }.compact
          end
        end

        # Three reads over the loop's own invocations; one unit only when every
        # priced receipt agrees on it. The cache read rides beside the input
        # count with its rate (`UsageRecord.cache_hit_rate`): a tool loop's
        # dominant cost term, invisible in a spend that summed it away
        # (evals 12a, the cache columns).
        def spend_for(agent_run)
          records = UsageRecord.where(
            model_invocation_public_id: ModelInvocation.where(agent_run_id: agent_run.id).select(:public_id)
          )
          input, output, cache_read, cost = records.pick(
            Arel.sql("COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0), " \
                     "COALESCE(SUM(cache_read_tokens), 0), SUM(cost_amount)")
          )
          units = records.where.not(cost_unit: nil).distinct.pluck(:cost_unit)
          {
            input_tokens: input.to_i, output_tokens: output.to_i,
            cache_read_tokens: cache_read.to_i, cache_hit_rate: UsageRecord.cache_hit_rate(input.to_i, cache_read.to_i),
            cost_amount: cost&.to_s("F"), cost_unit: (units.sole if units.one?),
            by_model: spend_by_model(records),
          }
        end

        # THE SAME RECEIPTS, SPLIT BY THE MODEL EACH NAMES: a loop runs on
        # more than one model when a step is re-run elsewhere (a declared
        # fallback after a refusal, a result-mail switch), and whose spend
        # it was is the receipt's own catalog key (`provider/model`) — never
        # a re-pricing. A model's unit stands only when its priced receipts
        # agree on one (MIN = MAX; nulls ignored).
        def spend_by_model(records)
          records.group(:catalog_model_ref).order(:catalog_model_ref).pluck(
            :catalog_model_ref,
            Arel.sql("COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0), " \
                     "COALESCE(SUM(cache_read_tokens), 0), SUM(cost_amount), MIN(cost_unit), MAX(cost_unit)")
          ).to_h do |model, input, output, cache_read, cost, low_unit, high_unit|
            [model, {
              input_tokens: input.to_i, output_tokens: output.to_i, cache_read_tokens: cache_read.to_i,
              cost_amount: cost&.to_s("F"), cost_unit: (low_unit if low_unit == high_unit),
            }]
          end
        end
    end
  end
end
