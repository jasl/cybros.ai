module Executors
  # The host's initial runner binding, one function for the creators that
  # write it — conversation create and standalone-loop create; a fork
  # COPIES its source's, a loop-backed loop derives its conversation's. The
  # runner the creator NAMES, else none: the kernel infers no execution
  # host (the creator names actively; unnamed is allowed and unbound, and a
  # runner-tool call on a nil binding fails `tool_not_served` at start). A
  # name is refused unless it is a live runner-kind row eligible for the
  # principal — a row fact (active, credential ready, not shutdown-pending,
  # in scope), never an announcement: an agent application's address never
  # binds, a tools provider never does.
  module InitialRunner
    Decision = Data.define(:executor) do
      def refused? = false
    end

    Refusal = Data.define(:error_key, :detail) do
      def refused? = true
    end

    NOT_ELIGIBLE = "runner_not_eligible".freeze

    module_function

    # `requested` is the public id the door admitted (nil/blank = none).
    def for(requested:, principal:)
      return Decision.new(executor: nil) if requested.blank?

      runner = TaskExecutor.live.where(executor_kind: :runner).find_by(public_id: requested)
      unless runner&.eligible_for?(principal)
        return Refusal.new(error_key: NOT_ELIGIBLE,
          detail: "#{requested} is not a live runner eligible for this host's answerer")
      end

      Decision.new(executor: runner)
    end
  end
end
