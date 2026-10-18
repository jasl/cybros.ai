module Runs
  module Tasks
    # Compact now: the kernel picks no threshold, so a caller who sees a
    # round getting expensive says so. Task-grained — the round carries the
    # history — and queued only, since a started round's request is sealed.
    class Compact
      Command = Data.define(:run, :task_key, :acting_user)

      Result = Data.define(:outcome, :node, :summary_task_key) do
        class << self
          def accepted(node, key) = new(outcome: :accepted, node: node, summary_task_key: key)
          def refused(code) = new(outcome: code, node: nil, summary_task_key: nil)
        end

        def accepted? = outcome == :accepted
      end

      class << self
        def call(command)
          run = command.run
          refusal = entry_refusal(run, command.acting_user)
          return Result.refused(refusal) if refusal

          result = run.with_lock { arm(command) }
          ScheduleJob.perform_later(run.id) if result.accepted?
          result
        end

        # Eligibility reads policy and current state without rendering history.
        # A permitted candidate can still have nothing to compact at submission.
        def refusal_for(run:, node:, acting_user:)
          entry_refusal(run, acting_user) || run_refusal(run) || node_refusal(node)
        end

        private

          def entry_refusal(run, acting_user)
            if !run.writable_by?(acting_user)
              :not_authorized
            elsif run.overridden?
              :not_adjudicable
            end
          end

          def arm(command)
            run = command.run
            refusal = run_refusal(run)
            return Result.refused(refusal) if refusal

            node = run.tasks.find_by(node_key: command.task_key)
            refusal = node_refusal(node) || Conversations::Compaction::Arm.refusal_for_round(node)
            return Result.refused(refusal) if refusal

            # Manual requests carry no overshoot, so the arm summarizes.
            # A configured pre-compaction hook may be its first step.
            repaired = Conversations::Compaction::Arm.call(
              run: run, node: node,
              trigger: Conversations::Compaction::Trigger.manual(user: command.acting_user)
            )
            repaired ? Result.accepted(node, repaired.summary_task_key) : Result.refused(:arm_failed)
          end

          def run_refusal(run)
            if run.tombstoned?
              :not_found
            elsif !Run::ADJUDICABLE_STATUSES.include?(run.status) || run.overridden?
              :not_adjudicable
            end
          end

          def node_refusal(node)
            if node.nil?
              :task_not_found
            elsif !node.model_task?
              :not_compactable
            elsif node.status != "queued"
              :task_not_queued
            else
              Conversations::Compaction::Arm.policy_refusal(node)
            end
          end
      end
    end
  end
end
