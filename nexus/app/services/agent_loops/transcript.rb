module AgentLoops
  # THE THREAD — what a person sees, never the graph (the
  # projection): the SPINE's rounds by the
  # kernel's mark, each carrying the calls it READ and the branches
  # hanging under them, found by the key grammar and the round's own
  # reading list — never `agent_loop_edges`. A loop has no ceiling, so
  # every rule here keeps a page's cost independent of the loop's size:
  # cursor pages, a bounded fan per round, rows only, no body loaded.
  #
  # ONE builder, three products: the page (and the same page under a
  # branch's `prefix`), the settled `round` snapshot the transcript feed
  # publishes, and the timeline's `turn_rounds` — the spine's rows with
  # no fan and no mark, because a turn shows rounds, never a graph.
  class Transcript
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100
    # Per round. The overflow is COUNTED — codex's "Ran N commands" shape —
    # and reachable through the round's own tasks.
    CALLS_SHOWN = 24
    # A kernel-minted round `r<n>` READS the calls `r<n>t*`: ExpandRound
    # mints the fan and its continuation from ONE number, so a round's
    # calls carry its continuation's number (`r1` makes `r2t0`; `r2` reads
    # it). An authored spine key (`w1`, `work-2`, `summary`) reads no fan
    # and answers empty calls. A prefixed key under a call (`r2t0-…`) is a
    # branch's row, never a call — `position('-' in node_key) = 0` keeps
    # the fan's slots for the calls.
    ROUND_KEY = /\Ar\d+\z/
    MODEL = AgentLoopNodes::ModelTask.sti_name
    TOOL = AgentLoopNodes::ToolTask.sti_name
    BRANCH = Tasks::Compile::BRANCH
    # The two RANGE bounds the grammar gives for free under collation `C`
    # (bytewise; the migration 2026-09-14): a round's fan is `[r<n>t, r<n>u)`
    # — `u` is `t` + 1 and nothing of the alphabet lies between — and a
    # call's branch is `[<call>-, <call>.)` — `.` is `-` + 1 and outside the
    # alphabet. Both ride the unique btree `(agent_loop_id, node_key)`.
    FAN_OPEN = "t".freeze
    FAN_CLOSE = "u".freeze
    UNDER_OPEN = "-".freeze
    UNDER_CLOSE = ".".freeze

    # `refusal` is the one miss a page can answer: a `prefix` naming no
    # call of this loop — the task verbs' word for a missing key.
    Result = Data.define(:rounds, :next_before, :has_older, :refusal) do
      def self.refused(code) = new(rounds: [], next_before: nil, has_older: false, refusal: code)
      def refused? = !refusal.nil?
    end

    class << self
      def call(...) = new(...).call

      # The row the feed publishes when a round settles, built through the
      # page's own code so the two vocabularies cannot drift — scoped to
      # the one node, so it costs what one row costs under the loop lock.
      # STABLE by construction: a round's calls are `r<n>t*` by its own
      # number and are settled before the round runs.
      def round_snapshot(node)
        new(agent_loop: node.agent_loop, scope: [node]).send(:round, node)
      end

      def call_snapshot(node)
        new(agent_loop: node.agent_loop, scope: [node]).send(:call_row, node)
      end

      # The variant block's rows: each loop's newest SPINE rounds in chain
      # order, batched over a timeline page's loops — one windowed query,
      # then this page's own batches over the union — so a page costs what
      # a page costs whatever the loops grew to. No fan statement and no
      # mark: `calls`, `branches` and `spine` are absent, because every
      # row here is spine by construction and a constant is not a fact — a
      # turn shows rounds, never the graph.
      def turn_rounds(agent_loops, limit: DEFAULT_LIMIT)
        return {} if agent_loops.empty?

        nodes = newest_rounds(agent_loops.map(&:id), limit)
        page = new(agent_loop: nil, scope: nodes, fan: false)
        nodes.group_by(&:agent_loop_id).transform_values do |rounds|
          rounds.map { |node| page.send(:round, node).except(:spine) }
        end
      end

      private

        # Windowed per loop in SQL, like a page's fans: the newest `limit`
        # visible spine rounds of every loop, read back in chain order.
        def newest_rounds(agent_loop_ids, limit)
          windowed = AgentLoopNode
            .where(agent_loop_id: agent_loop_ids, type: MODEL)
            .where("continuation_source IS DISTINCT FROM ?", BRANCH)
            .where.not(transcript_visibility: "hidden")
            .select("agent_loop_nodes.*",
              "ROW_NUMBER() OVER (PARTITION BY agent_loop_id ORDER BY id DESC) AS position")
          AgentLoopNode.find_by_sql(
            "SELECT * FROM (#{windowed.to_sql}) ranked WHERE position <= #{limit.to_i} ORDER BY id"
          )
        end
    end

    # `agent_loop` is nil only under a batched scope spanning several
    # loops, whose rows carry no fan. `prefix` is a call key: the page is
    # then the branch under it — its roots and its own rounds — in the
    # same envelope, built by the same code.
    def initialize(agent_loop:, before: 0, limit: DEFAULT_LIMIT, prefix: nil, scope: nil, fan: true)
      @agent_loop = agent_loop
      @agent_loop_id = agent_loop&.id
      @before = before.to_i
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @prefix = prefix.presence
      # A single-node scope skips the window entirely: the batches below
      # key on it, so a snapshot costs what one row costs.
      @scope = scope
      @fan = fan
    end

    def call
      return Result.refused(:task_not_found) if @prefix && !call_exists?

      page = rounds_page
      Result.new(
        rounds: page.reverse.map { |node| round(node) },
        next_before: (TranscriptCursor.encode(page.last.id) if @has_older),
        has_older: @has_older,
        refusal: nil
      )
    end

    private

      TranscriptCursor = AgentLoopNode::TranscriptCursor

      # LIMIT + 1 detects a next page rather than inferring one; plumbing
      # is what `transcript_visibility` hides.
      def rounds_page
        return @scope if @scope

        @rounds_page ||= begin
          rows = @prefix ? branch_rows : spine_rows
          @has_older = rows.length > @limit
          rows.first(@limit)
        end
      end

      # THE SPINE, by the kernel's mark and never by a key's shape:
      # a round whose mark is not `branch`, a NULL mark included.
      def spine_rows
        scope = @agent_loop.spine_nodes
          .where.not(transcript_visibility: "hidden")
          .order(id: :desc)
          .limit(@limit + 1)
        scope = scope.where(id: ...@before) if @before.positive?
        scope.to_a
      end

      # A branch hangs under a CALL: the prefix must name a tool row of this
      # loop, and one keyed probe says so before the walk — an empty branch
      # and a key the loop never had are different answers.
      def call_exists?
        @agent_loop.agent_loop_nodes.where(type: TOOL).exists?(node_key: @prefix)
      end

      # THE BRANCH UNDER A CALL, in ONE recursive statement over the round's
      # own reading list (no edge load). Seeded by the VISIBLE model rows
      # the call prefixes — a `task` call's `-model-1`, a compose's members
      # — then every branch round whose FIRST read is a row already found: a
      # branch's own continuations are `r<m>` keys off the loop-global
      # counter with no prefix link to their root, and
      # `input_from_node_keys[1]` — the round a continuation continues,
      # which Compile always writes first — is the one row fact that links
      # them (`AgentLoop#spine_tail` walks the same column). A hidden root
      # seeds nothing, so its chain is unreachable: hidden reaches neither
      # the window nor the feed. The reading-list column carries the
      # database's collation and the key column `C`; the explicit COLLATE
      # says which the join compares under.
      def branch_rows
        older = @before.positive? ? "AND agent_loop_nodes.id < #{@before.to_i}" : ""
        AgentLoopNode.find_by_sql(AgentLoopNode.sanitize_sql_array([<<~SQL.squish, *branch_binds]))
          WITH RECURSIVE branch(id, node_key) AS (
            SELECT id, node_key FROM agent_loop_nodes
             WHERE agent_loop_id = ? AND type = ? AND transcript_visibility <> 'hidden'
               AND node_key >= ? AND node_key < ?
            UNION
            SELECT n.id, n.node_key FROM agent_loop_nodes n
              JOIN branch ON n.input_from_node_keys[1] COLLATE "C" = branch.node_key
             WHERE n.agent_loop_id = ? AND n.type = ? AND n.continuation_source = ?
          )
          SELECT agent_loop_nodes.* FROM agent_loop_nodes
           WHERE agent_loop_nodes.id IN (SELECT id FROM branch)
             AND agent_loop_nodes.transcript_visibility <> 'hidden' #{older}
           ORDER BY agent_loop_nodes.id DESC LIMIT #{@limit + 1}
        SQL
      end

      def branch_binds
        [@agent_loop_id, MODEL, "#{@prefix}#{UNDER_OPEN}", "#{@prefix}#{UNDER_CLOSE}",
         @agent_loop_id, MODEL, BRANCH]
      end

      # THE ROW. `spine` is the kernel's mark; `compacted_before` /
      # `pruned_before` are the cut marker a reader draws the line from,
      # absent on every other round; `calls` are the tool rows this round
      # READ, bounded and counted; `branches` the calls under which a
      # VISIBLE branch hangs — an ask's and a spawn's await is hidden, so
      # neither is one. No body is loaded at any point.
      def round(node)
        {
          task_key: node.node_key,
          spine: spine?(node),
          status: AgentLoops::TaskProjection.public_status(node.status),
          visibility: node.transcript_visibility,
          text_preview: node.output_preview,
          text_bytes: node.output_size_bytes,
          usage: usage_for(node),
          error: error_for(node),
          compacted_before: (node.node_key if node.arrived_summary),
          pruned_before: node.pruned_before,
          started_at: node.started_at&.iso8601,
          completed_at: node.completed_at&.iso8601,
        }.compact.merge(fan_block(node))
      end

      def spine?(node) = node.continuation_source != BRANCH

      def fan_block(node)
        return {} unless @fan

        count, roots = fan_facts.fetch(node.node_key, [0, []])
        {
          calls: { count: count, items: fan_rows.fetch(node.node_key, []).map { |call| call_row(call) } },
          branches: roots,
        }
      end

      # `name` is what the model called (the alias when it used one), and
      # `tool` the kernel's wire name beside it when the two differ.
      def call_row(node)
        {
          task_key: node.node_key,
          tool_call_id: node.tool_call_id,
          name: node.called_name,
          tool: (node.tool_name if node.tool_alias),
          status: AgentLoops::TaskProjection.public_status(node.status),
          is_error: node.output_summary["is_error"],
          title: node.result_title,
          metadata: node.result_metadata.presence,
          output_preview: node.output_preview,
          output_bytes: node.output_size_bytes,
          started_at: node.started_at&.iso8601,
          completed_at: node.completed_at&.iso8601,
        }.compact
      end

      # The page's kernel-minted rounds: the only rows whose fan the key
      # grammar names.
      def fan_keys
        @fan_keys ||= rounds_page.map(&:node_key).grep(ROUND_KEY)
      end

      # THE RANGES AS ROWS. One `VALUES` row per round — its key and its
      # fan's two bounds — and a LATERAL probe per row, so the statement
      # is structurally one btree range per round whatever the loop holds
      # (an OR of twenty ranges, and a plain join on them, are both priced
      # as the loop's rows and demoted to a filter on a small loop; the
      # EXPLAIN pin caught each). The bounds carry the column's own
      # collation by name: a `VALUES` column is text under the database's,
      # and the comparison must be the index's.
      def fan_values
        @fan_values ||= AgentLoopNode.sanitize_sql_array([
          "(VALUES #{Array.new(fan_keys.length, "(?, ?, ?)").join(", ")}) AS fan(round_key, lo, hi)",
          *fan_keys.flat_map { |key| [key, "#{key}#{FAN_OPEN}", "#{key}#{FAN_CLOSE}"] },
        ])
      end

      FAN_RANGE = 'agent_loop_nodes.agent_loop_id = ? AND agent_loop_nodes.node_key >= (fan.lo COLLATE "C") ' \
                  'AND agent_loop_nodes.node_key < (fan.hi COLLATE "C")'.freeze

      # THE CALLS, ONE STATEMENT: per round the first CALLS_SHOWN of its
      # fan in id order, so a page of wide fans cannot materialise
      # thousands of rows to show a dozen; each row carries the round its
      # range named.
      def fan_rows
        @fan_rows ||= begin
          if fan_keys.empty?
            {}
          else
            AgentLoopNode.find_by_sql(AgentLoopNode.sanitize_sql_array([<<~SQL.squish, @agent_loop_id, TOOL]))
              SELECT calls.*, fan.round_key AS fan_round
                FROM #{fan_values}
                CROSS JOIN LATERAL (
                  SELECT agent_loop_nodes.* FROM agent_loop_nodes
                   WHERE #{FAN_RANGE}
                     AND agent_loop_nodes.type = ? AND agent_loop_nodes.transcript_visibility <> 'hidden'
                     AND position('#{UNDER_OPEN}' in agent_loop_nodes.node_key) = 0
                   ORDER BY agent_loop_nodes.id LIMIT #{CALLS_SHOWN.to_i}
                ) calls
               ORDER BY calls.id
            SQL
              .group_by { |call| call.read_attribute(:fan_round) }
          end
        end
      end

      # THE COUNTS AND THE ROOTS, ONE STATEMENT over the same ranges: per
      # round, how many calls it read (the whole, past the window), and
      # the call keys under which a visible prefixed row exists.
      def fan_facts
        @fan_facts ||= begin
          if fan_keys.empty?
            {}
          else
            sql = AgentLoopNode.sanitize_sql_array([<<~SQL.squish, TOOL, @agent_loop_id])
              SELECT fan.round_key, facts.calls, facts.roots
                FROM #{fan_values}
                CROSS JOIN LATERAL (
                  SELECT COUNT(*) FILTER (WHERE agent_loop_nodes.type = ?
                                            AND position('#{UNDER_OPEN}' in agent_loop_nodes.node_key) = 0) AS calls,
                         string_agg(DISTINCT split_part(agent_loop_nodes.node_key, '#{UNDER_OPEN}', 1), ',')
                           FILTER (WHERE position('#{UNDER_OPEN}' in agent_loop_nodes.node_key) > 0) AS roots
                    FROM agent_loop_nodes
                   WHERE #{FAN_RANGE} AND agent_loop_nodes.transcript_visibility <> 'hidden'
                ) facts
            SQL
            # `with_connection`, not `.connection`: the latter raises now.
            AgentLoopNode.with_connection { |connection| connection.select_rows(sql) }.to_h do |key, calls, roots|
              [key, [calls.to_i, roots.to_s.split(",").sort_by { |root| fan_order(root) }]]
            end
          end
        end
      end

      # A fan's own order: `r<n>t<i>` by `i`; an authored key inside the
      # range after them, by its bytes.
      def fan_order(key)
        index = key[/#{FAN_OPEN}(\d+)\z/, 1]
        [index ? 0 : 1, index.to_i, key]
      end

      # Batched like the fans. The latest attempt is the round's cost: a
      # failed first try's empty numbers are not what the round spent.
      def invocation_public_ids
        @invocation_public_ids ||= ModelInvocation
          .where(id: rounds_page.filter_map(&:selected_model_invocation_id))
          .pluck(:id, :public_id).to_h
      end

      def usage_records
        @usage_records ||= UsageRecord
          .where(model_invocation_public_id: invocation_public_ids.values)
          .order(:attempt_ordinal)
          .index_by(&:model_invocation_public_id)
      end

      def usage_for(node)
        public_id = invocation_public_ids[node.selected_model_invocation_id]
        record = public_id && usage_records[public_id]
        return nil if record.nil?

        {
          input_tokens: record.input_tokens,
          output_tokens: record.output_tokens,
          total_tokens: record.total_tokens,
          cache_read_tokens: record.cache_read_tokens,
          cache_creation_tokens: record.cache_creation_tokens,
        }.compact
      end

      def error_for(node)
        return nil if node.error_key.blank?

        { key: node.error_key, detail: node.error_detail }.compact
      end
  end
end
