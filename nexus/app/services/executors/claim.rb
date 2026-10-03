module Executors
  # The executor plane's claim: single delivery — two processes of one
  # address see the same parked row, so the race is resolved here under the
  # node lock with a token that rotates per claim. One clock — the claim
  # re-arms the park's own deadline, and the claimant may extend it
  # (Executors::Extend), bounded and narrated. The grant is to the EXECUTOR
  # the row is addressed to, never on a caller's standing, and never twice:
  # a row ever claimed in this generation is refused whether or not its
  # deadline passed. An ask or an approval is an inbox row with one answerer
  # by construction and is never claimed. The accepted answer's value is the
  # claimed row, its fresh token on it.
  class Claim
    Command = Data.define(:agent_loop, :task_key, :executor)

    def self.call(command) = new(command).call

    def initialize(command)
      @command = command
    end

    def call
      agent_loop = @command.agent_loop
      # Loop before node, the ladder's order; the executor and workspace
      # reads below are lock-free.
      agent_loop.with_lock do
        next Outcome.refused(:not_found) if agent_loop.tombstoned?

        node = agent_loop.agent_loop_nodes.lock.find_by(
          node_key: @command.task_key, type: AgentLoopNodes::PARKED_TYPES
        )
        next Outcome.refused(:not_found) if node.nil?

        grant(agent_loop, node)
      end
    end

    private

      # The claim preconditions, in order: the row is addressed to this
      # executor, or to a pool it is a member of (a kernel row has no
      # addressee and answers here); the row is of a claimable kind (an ask
      # or an approval never is); the executor is eligible for the loop's
      # ANSWERER (the principal every executor is judged for); the loop's
      # SPEAKER — its creator — still has write standing (level-triggered,
      # separate from the caller's own door); the row is a claimable park.
      # Two members racing one pool row resolve exactly as two runners
      # racing one addressed row: `held_by_another?`.
      def grant(agent_loop, node)
        executor = @command.executor
        return Outcome.refused(:not_addressed_here, node) unless
          node.addressed_executor_id == executor.id || Pool.member?(node, executor)
        return Outcome.refused(:not_claimable_kind, node) if other_inbox_kind?(node)
        return Outcome.refused(:not_eligible, node) unless executor.eligible_for?(agent_loop.answering_user)
        return Outcome.refused(:not_authorized, node) unless
          agent_loop.workspace.data_writable_by?(agent_loop.creating_user)
        return Outcome.refused(:task_not_claimable, node) unless
          claimable?(agent_loop, node)
        return Outcome.refused(:already_claimed, node) if held_by_another?(node)

        now = Time.current
        AgentLoops::Transition.node(
          node,
          claim_token: SecureRandom.uuid,
          claimed_at: now,
          # The public-id snapshot survives the claimant's reap.
          claimed_by_executor_id: executor.id,
          claimed_by_executor_public_id: executor.public_id,
          # The claim re-arms the ONE clock, so taking the work restarts
          # it: a grant against an already-passed deadline would hand out
          # work the engine has already decided to expire.
          await_started_at: now
        )
        Outcome.accepted(node)
      end

      def claimable?(agent_loop, node)
        node.started? && Inbox::ANSWERABLE_LOOP_STATUSES.include?(agent_loop.status) &&
          !AgentLoops::SourceWork.execution_stopped?(agent_loop)
      end

      # An ask or an approval IS an inbox row, of a kind nobody claims;
      # a tool row that is no longer anybody's inbox row — a settled one
      # — answers `task_not_claimable` below instead.
      def other_inbox_kind?(node)
        kind = node.inbox_kind
        kind.present? && kind != "tool_call"
      end

      # A row ever claimed in this generation is refused whether or not
      # its deadline passed — expiry is the sweep's alone: a second
      # taker inside the sweep's window would be the blind double-run
      # the effect profile exists to forbid.
      def held_by_another?(node) = node.claimed_at.present?
  end
end
