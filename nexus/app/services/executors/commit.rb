module Executors
  # The executor plane's commit ("re-read at claim AND at commit"): a
  # scoped finder, three level-triggered fences — lock-free reads before
  # Settle's loop lock (`task_executors` sits above `agent_loops` on the
  # ladder, and nothing here locks it) — then ONE `Parks::Settle` call. The
  # address proves the door and the token proves the claim, so a commit
  # from an executor the row does not name is refused before the token is
  # looked at. An ask commits here with NO token: the row names its
  # addressee and that is the door — Settle admits the tokenless await
  # exactly as it admits the person's answer. Two doors, one Settle, as a
  # recorded difference: the executor door proves an address, the member
  # door proves standing, and the second answer is `idle`. The answer is
  # Settle's own (`applied | idle | refused`), so one renderer serves this
  # door and the person's resolution.
  class Commit
    Command = Data.define(
      :agent_loop, :task_key, :executor, :claim_token, :content, :structured_content,
      :result_type, :outcome, :is_error, :title, :metadata
    )

    Result = AgentLoops::Parks::Settle::Result

    def self.call(command) = new(command).call

    def initialize(command)
      @command = command
    end

    def call
      agent_loop = @command.agent_loop
      return Result.refused(:not_found) if agent_loop.tombstoned?

      # The parked row of either type; the fence reads its address.
      node = agent_loop.agent_loop_nodes.find_by(
        node_key: @command.task_key, type: AgentLoopNodes::PARKED_TYPES
      )
      return Result.refused(:not_found) if node.nil?

      fence(agent_loop, node) || settle(node)
    end

    private

      # A pool row is committed by its claimant only: an unclaimed one is
      # nobody's yet, and the fence names that before Settle would answer
      # `stale_claim`. A claimed result reconciles work already admitted:
      # Human shutdown closes new claims but retains this transport until the
      # claim settles. Settle alone verifies the token. Unclaimed asks still
      # need current eligibility, and every result retains the loop speaker's
      # write gate.
      def fence(agent_loop, node)
        executor = @command.executor
        return Result.refused(:not_addressed_here, node) unless
          node.addressed_executor_id == executor.id ||
          (Pool.row?(node) && node.claimed_by_executor_id == executor.id)
        return Result.refused(:not_eligible, node) unless eligible_to_commit?(executor, node, agent_loop)
        return Result.refused(:not_authorized, node) unless
          agent_loop.workspace.data_writable_by?(agent_loop.creating_user)

        nil
      end

      def eligible_to_commit?(executor, node, agent_loop)
        if node.claimed_by_executor_id == executor.id
          executor.active?
        else
          executor.eligible_for?(agent_loop.answering_user)
        end
      end

      def settle(node)
        AgentLoops::Parks::Settle.call(
          node: node, claim_token: @command.claim_token, content: @command.content,
          structured_content: @command.structured_content, result_type: @command.result_type,
          outcome: @command.outcome, is_error: @command.is_error,
          title: @command.title, metadata: @command.metadata,
          # A `resource_link` names THIS executor's own capture.
          creator: @command.executor
        )
      end
  end
end
