module Executors
  # THE CLAIMANT'S EXTENSION. One clock, no lease, no heartbeat — and a
  # claimant at work may move its own deadline: the row's current claimant
  # (the address AND the token), by at most the tool's announced park or the
  # kernel's hour, as often as the work needs. There is no cumulative
  # deadline; task cancellation or a loop force-stop can settle a live call.
  # The write is the ONE clock re-arm the claim and the
  # handoff use — `await_started_at`, with the deadline derived from it — so
  # the sweep's SQL twin follows with no second derivation, and a commit
  # that arrives after the deadline it did not move stays an expiry.
  # Narrated `task_deadline_extended`, so `rho watch` can say the runner
  # asked for more time. Loop before node, the ladder's order; the executor
  # and workspace reads are lock-free.
  class Extend
    # An hour bounds each extension, even when the announced timeout is
    # longer or absent. Once the claimant stops extending, this park's
    # deadline applies.
    MAX_EXTENSION_MS = 1.hour.in_milliseconds

    Command = Data.define(:agent_loop, :task_key, :executor, :claim_token, :timeout_ms)

    def self.call(command) = new(command).call

    def initialize(command)
      @command = command
    end

    # The accepted answer's value is the row, its clock moved.
    def call
      agent_loop = @command.agent_loop
      agent_loop.with_lock do
        next Outcome.refused(:not_found) if agent_loop.tombstoned?

        # The park row, second under its loop (the ladder's loops-before-nodes
        # order): the extension answers WHICH precondition failed, which a
        # CAS on the clock's 0 rows changed cannot say.
        node = agent_loop.agent_loop_nodes.lock.find_by(
          node_key: @command.task_key, type: AgentLoopNodes::PARKED_TYPES
        )
        next Outcome.refused(:not_found) if node.nil?

        extend(agent_loop, node)
      end
    end

    private

      # In order: the row is a claimed `dispatched` park on a loop that can
      # still be answered, before its deadline (a paused loop's clocks stand still); the caller
      # IS its claimant — the executor that took it AND the token the take
      # minted; the extension fits the bound. Then the one clock moves.
      def extend(agent_loop, node)
        now = agent_loop.effective_now
        return Outcome.refused(:not_extendable, node) unless extendable?(agent_loop, node, now)
        return Outcome.refused(:not_claimant, node) unless node.claimed_by?(@command.executor, token: @command.claim_token)
        return Outcome.refused(:extension_too_long, node) if @command.timeout_ms > bound_ms(node)

        rearm(agent_loop, node, now)
        Outcome.accepted(node)
      end

      def extendable?(agent_loop, node, now)
        node.status == "dispatched" && node.claimed_at.present? &&
          Inbox::ANSWERABLE_LOOP_STATUSES.include?(agent_loop.status) && !node.deadline_passed?(now)
      end

      # The tool's announced park bounds the extension when it announced
      # one (frozen on the row at dispatch); the kernel's hour bounds it
      # either way.
      def bound_ms(node) = [node.announced_timeout_ms, MAX_EXTENSION_MS].compact.min

      # The deadline is `await_started_at + effective_timeout_ms` on the row
      # and in the sweep's SQL alike, so "the deadline is now plus the
      # extension" is written as the one clock the derivation reads — at
      # the loop's VIRTUAL clock, as the handoff re-arms it.
      def rearm(agent_loop, node, now)
        AgentLoops::Transition.node(
          node, await_started_at: now + (@command.timeout_ms - node.effective_timeout_ms) / 1000.0
        )
        AgentLoop::Narration.record(agent_loop, [{
          type: "task_deadline_extended",
          payload: {
            "task_key" => node.node_key,
            "deadline_at" => node.deadline_at.iso8601,
            "by" => @command.executor.public_id,
            "timeout_ms" => @command.timeout_ms,
          },
        }])
      end
  end
end
