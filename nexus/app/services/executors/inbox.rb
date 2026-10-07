module Executors
  # The executor's view of the rows addressed to it, across every workspace,
  # read on the executor plane: the workspace is not a scope here — the
  # address is. Level-triggered and complete, so a lost push costs
  # milliseconds and never a task; scoped to live loops, so a dying one
  # drains. The scheduler wrote the addressee at start and the frontier
  # reads it — a kernel row carries none and never lists. An ask is listed
  # for its addressee and never claimed: the row says `claimed: false` for
  # as long as it stands. A POOL row (addressed by role alone) lists for
  # every eligible tools provider announcing its name until one claims it,
  # then for the claimant alone — a crashed claimant sees the row it holds,
  # another member never sees a row it can no longer take. An APPROVAL row
  # lists for the addressed agent application with its `tool_name`,
  # `tool_input` and the frozen `effect_profile` the approver reads,
  # `claimed: false` for as long as it stands, and ends by the member verbs
  # or the clock.
  class Inbox
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 200
    # Answerable, not merely running: a graceful stop's parks must settle
    # for its drain to finish. A paused loop's clocks are frozen, so nothing is handed out.
    ANSWERABLE_LOOP_STATUSES = %w[running canceling].freeze

    Result = Data.define(:tasks, :next_after)

    class << self
      def call(...) = new(...).call

      # What a runner needs to run the call; the claim door renders the same
      # object, or a field ends up in only one of them. Never a node id, an
      # edge, a countdown or — on a runner's row — the effect profile; the
      # APPROVAL row is the one kind that carries it, because it is what the
      # approver reads. `claimed` is EVER claimed in this generation: a
      # lapsed claim is not re-granted, expiry is the sweep's alone. An ask
      # carries its question — the same read the member task detail takes —
      # and no tool fields. `scope` rides a kernel-named row alone (below);
      # `conversation_public_id` rides EVERY row — the loop's conversation,
      # an explicit null for a standalone loop — because what a call starts
      # on a runner follows the conversation, and the runner learns whose it
      # is from the row, never from a lookup of its own. `parent_public_id`
      # rides beside it the same way: the conversation's PARENT, off the
      # snapshot the kernel keeps on a spawned child
      # (`Conversation#parent_conversation_public_id`, the weak reference
      # that survives the parent's reap) — null for a root conversation and
      # for a standalone loop — so a runner elsewhere resolves a child's
      # environment by its parent's received binding with no relay in the
      # path. A structural fact the kernel already holds; no key of any
      # argument is interpreted. `timeout_ms` is the park's budget the
      # deadline is cut from — authored, else announced, else the kernel's;
      # an ask's or a wait's clamped to 24 h; a held row's the 24 h hold —
      # stated so an executor names the budget it was held to without a
      # clock; a claim or an extension moves `deadline_at`, never this.
      # Every task also names its required workspace, including standalone loops, so
      # execution never infers its scope from a consumer's mutable default.
      def row(node)
        {
          kind: node.inbox_kind,
          run_public_id: node.agent_run.public_id,
          workspace_public_id: node.agent_run.workspace.public_id,
          task_key: node.node_key,
          prompt: (node.prompt if node.await?),
          options: (node.ask_options if node.await?),
          multi: (node.ask_multi if node.await?),
          tool_name: node.tool_name,
          tool_alias: node.tool_alias,
          target: AgentRuns::TaskProjection.target(node),
          tool_input: (node.tool_input if node.tool_call?),
          effect_profile: (node.effect_profile if node.inbox_kind == "approval"),
          scope: (scope_of(node) if node.tool_call? && Nexus::ToolRegistry.kernel_name?(node.tool_name)),
          tool_call_id: node.tool_call_id,
          started_at: node.started_at&.iso8601,
          deadline_at: node.wall_deadline_at&.iso8601,
          timeout_ms: node.effective_timeout_ms,
          claimed: node.claimed_at.present?,
          addressed_to: {
            role: node.addressed_role,
            executor_public_id: node.addressed_executor&.public_id,
          }.compact,
        }.compact.merge(
          conversation_public_id: node.agent_run.conversation&.public_id,
          parent_public_id: node.agent_run.conversation&.parent_conversation_public_id
        )
      end

      # THE KERNEL STATING WHOSE ROW THIS IS: not an interpretation of tool
      # arguments — `tool_input` passes through untouched — but the same
      # kind of fact as `addressed_to` and `run_public_id`. Present
      # only on a row whose name is a kernel canonical: an overridden one,
      # or a `skill` row addressed to its announcer — the two ways a kernel
      # name reaches the inbox; absent on every other row.
      # Memory overrides receive only the execution's currently available
      # named database anchors and their access modes. Source-routed skills
      # retain the host's three-field context stamp.
      def scope_of(node)
        agent_run = node.agent_run
        if Nexus::ToolRegistry.resolve(node.tool_name).to_s.start_with?("nexus.memory.")
          return MemoryDocuments::Context.new(workspace: agent_run.workspace,
            conversation: agent_run.conversation, principal: agent_run.creating_user,
            configuration: agent_run.memory_context).projection
        end
        {
          workspace_public_id: agent_run.workspace.public_id,
          conversation_public_id: agent_run.conversation&.public_id,
          user_public_id: agent_run.memory_principal.controlling_human&.public_id,
        }
      end
    end

    # The credential always names an executor: the door authenticated it.
    def initialize(executor:, after: 0, limit: DEFAULT_LIMIT)
      @executor = executor
      @after = after.to_i
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
    end

    # The cursor is the last FETCHED id, so a member whose eligibility
    # excludes a pool row pages past it rather than re-reading it forever.
    def call
      fetched = frontier.to_a
      rows = fetched.select { |node| listable?(node) }
      Result.new(
        tasks: rows.map { |node| row(node) },
        next_after: (InboxCursor.encode(fetched.last.id) if fetched.length == @limit)
      )
    end

    private

      InboxCursor = AgentRunTask::InboxCursor

      # The park each kind rests in while somebody outside the kernel is
      # asked for it: a `dispatched` tool row, an `awaiting_input` ask, and
      # a tool row HELD for its approver — the addressed frontier's shape;
      # the pool branch below stays `dispatched`-only, so an approval row
      # never pools.
      PARKED_STATUS_SQL = <<~SQL.squish.freeze
        (agent_run_tasks.type = ? AND agent_run_tasks.status = 'dispatched')
        OR (agent_run_tasks.type = ? AND agent_run_tasks.status = 'awaiting_input')
        OR (agent_run_tasks.type = ? AND agent_run_tasks.status = 'needs_approval')
      SQL

      # The pool-frontier index's shape: the `dispatched` tool rows
      # addressed to the role alone whose name this provider announces,
      # unclaimed or claimed by it. Only a tools provider reads it, so a
      # runner's poll keeps the addressed-frontier plan alone.
      POOL_FRONTIER_SQL = <<~SQL.squish.freeze
        agent_run_tasks.addressed_executor_id IS NULL
          AND agent_run_tasks.addressed_role = :role
          AND agent_run_tasks.type = :tool_type
          AND agent_run_tasks.status = 'dispatched'
          AND agent_run_tasks.tool_name IN (:names)
          AND (agent_run_tasks.claimed_by_executor_id IS NULL
            OR agent_run_tasks.claimed_by_executor_id = :executor_id)
      SQL

      # The addressed-frontier index's shape: the parked rows addressed to
      # this executor, by the status each type parks in — a `dispatched`
      # tool row, an `awaiting_input` ask; a `running` row is the kernel's
      # and carries no addressee, a tokened await and a Human loop's ask
      # carry none either — under every live, answerable loop. A tools
      # provider's frontier is that OR the pool's.
      def frontier
        AgentRunTask
          .joins(:agent_run)
          .where(type: AgentRunTasks::PARKED_TYPES)
          .merge(addressee)
          .where(PARKED_STATUS_SQL,
            AgentRunTasks::ToolTask.sti_name, AgentRunTasks::AwaitTask.sti_name,
            AgentRunTasks::ToolTask.sti_name)
          .where(agent_runs: { status: ANSWERABLE_LOOP_STATUSES, tombstoned_at: nil })
          .where(id: (@after + 1)..)
          # The loop's three anchors: workspace and conversation are every row's
          # reads, the creator is the stamp's, and the turn's answerer is `listable?`'s
          # (the loop derives it from its turn) — small preloads, so a
          # provider's poll stays short.
          .includes(:addressed_executor, :target_executor, :content_bodies,
            agent_run: [:workspace, :conversation, :creating_user,
                         { conversation_turn_variant: { conversation_turn: :answering_user } }])
          .order(:id)
          .limit(@limit)
      end

      def addressee
        addressed = AgentRunTask.where(addressed_executor_id: @executor.id)
        names = @executor.served_tools.map { |entry| entry["name"] }
        return addressed unless @executor.tool_provider? && names.any?

        addressed.or(AgentRunTask.where(POOL_FRONTIER_SQL, role: Pool::ROLE,
          tool_type: AgentRunTasks::ToolTask.sti_name, names: names, executor_id: @executor.id))
      end

      # A pool row is a member's only while the member is eligible for the
      # loop's ANSWERER — read in Ruby, as addressing read it; the executor
      # is one object, so its readiness is read once per call.
      def listable?(node)
        !Pool.row?(node) || @executor.eligible_for?(node.agent_run.answering_user, readiness:)
      end

      def readiness
        @readiness ||= TaskExecutor.credential_readiness_for([@executor])
      end

      # Every parked tool is here, claimed or not, so a runner back from a
      # crash sees the work it holds; the row says whether it is takeable.
      def row(node) = self.class.row(node)
  end
end
