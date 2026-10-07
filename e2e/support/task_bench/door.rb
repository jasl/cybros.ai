module E2E
  module TaskBench
    # Classify the delegation in a scored message from its resolved calls.
    class Door < Data.define(:kind, :members, :beside)
      START_PROCESS = "start_process".freeze
      SCOUT = "scout".freeze
      TASK_FAN = "task_fan".freeze
      TASK_ONE = "task_one".freeze

      class << self
        def kind(calls)
          tasks = calls.count(&:task?)
          if tasks >= 2
            around(TASK_FAN, calls, tasks, &:task?)
          elsif tasks == 1
            around(TASK_ONE, calls, tasks, &:task?)
          elsif calls.any?(&:spawn?)
            around("spawn", calls, 0, &:spawn?)
          elsif calls.any? { |call| call.tool == START_PROCESS }
            around(START_PROCESS, calls, 0) { |call| call.tool == START_PROCESS }
          else
            around(calls.empty? ? "none" : "plain", calls, 0) { false }
          end
        end

        private

          def around(kind, calls, members, &own)
            new(kind: kind, members: members, beside: calls.reject(&own).map(&:name).uniq)
          end
      end

      def fields = { "door_kind" => kind, "members" => members, "beside" => beside }
    end
  end
end
