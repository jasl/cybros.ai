module Executors
  module TaskOperations
    class Access
      def initialize(run:, task_key:, executor:, claim_token:)
        @run = run
        @task_key = task_key
        @executor = executor
        @claim_token = claim_token.to_s
      end

      def read
        node = find_node
        refusal = read_refusal(node)
        refusal ? Outcome.refused(refusal) : yield(node)
      end

      def mutate(admission: true)
        # All task writers serialize on this loop, including expiry and Stop.
        # The subordinate operation rows need no independent lock.
        @run.with_lock do
          node = find_node
          refusal = read_refusal(node) || mutation_refusal(node, admission: admission)
          refusal ? Outcome.refused(refusal) : yield(node)
        end
      end

      private

        def find_node
          @run.tasks.find_by(node_key: @task_key, type: Tasks::ToolTask.sti_name)
        end

        def read_refusal(node)
          return :not_found if @run.tombstoned? || node.nil?
          return :not_claimant unless node.claimed_by?(@executor, token: @claim_token)

          nil
        end

        def mutation_refusal(node, admission:)
          eligible = admission ? @executor.eligible_for?(@run.answering_user) : @executor.active?
          return :not_eligible unless eligible
          return :not_authorized unless @run.workspace.data_writable_by?(@run.creating_user)
          return :execution_stopped if @run.terminal? || Runs::SourceWork.execution_stopped?(@run)
          return :execution_paused if admission && @run.paused?
          return :execution_stopped if admission && !@run.running?
          return :task_not_running unless node.status == "dispatched"
          return :claim_expired if node.deadline_passed?(@run.effective_now(DatabaseClock.now))

          nil
        end
    end
  end
end
