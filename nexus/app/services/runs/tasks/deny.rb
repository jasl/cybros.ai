module Runs
  module Tasks
    # THE APPROVER'S REFUSAL: a row resting at `needs_approval` fails
    # `approval_denied` with the approver's reason as the detail the model
    # reads, then the fact is stamped — who declined, of what kind, when.
    # The row's own `on_failure` decides the cascade: a model-composed call
    # is `absorb`, so the next round reads the declined sentence and
    # corrects itself; an authored `halt` step holds.
    class Deny
      ADJUDICABLE_LOOP_STATUSES = Retry::ADJUDICABLE_LOOP_STATUSES
      ERROR_KEY = "approval_denied".freeze

      Command = Data.define(:run, :task_key, :acting_user, :reason) do
        def initialize(reason: nil, **) = super
      end

      Result = Approve::Result

      class << self
        def call(command)
          new(command).call
        end
      end

      def initialize(command)
        @command = command
      end

      def call
        unless @command.run.writable_by?(@command.acting_user)
          return Result.refused(:not_authorized)
        end

        run = @command.run
        return Result.refused(:not_adjudicable) if run.overridden?

        result, resumed = run.with_lock { adjudicate(run) }
        ScheduleJob.perform_later(run.id) if resumed
        result
      end

      private

        def adjudicate(run)
          return [Result.refused(:not_found), false] if run.tombstoned?
          unless ADJUDICABLE_LOOP_STATUSES.include?(run.status) && !run.overridden?
            return [Result.refused(:not_adjudicable), false]
          end

          node = run.tasks.find_by(node_key: @command.task_key)
          return [Result.refused(:task_not_found), false] if node.nil?
          return [Result.refused(:not_awaiting_approval), false] unless node.held?

          # An expired park has no approver's decision to record. The same
          # owner as the sweep settles it and schedules its failure policy.
          if Parks::Settle.call(node: node, timeout: true).moved?
            return [Result.refused(:not_awaiting_approval), false]
          end

          # The one failure write first — a decided row never rests at the
          # stage (invariant 11), so the fact lands on the failed row in a
          # second narrated write: the stream reads the failure, then who declined.
          FailNode.call(run: run, node: node, error_key: ERROR_KEY,
            error_detail: @command.reason, worklist: [])
          Transition.node(node,
            approval_origin: Approve.origin_of(@command.acting_user),
            approved_by_user_id: @command.acting_user.id, approval_decided_at: Time.current)
          [Result.accepted(node), true]
        end
    end
  end
end
